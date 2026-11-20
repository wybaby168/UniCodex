import Darwin
import Foundation

enum AgentSocketError: LocalizedError {
    case unavailable
    case invalidDirectory
    case oversized

    var errorDescription: String? {
        switch self {
        case .unavailable: "工作台的本机 MCP 连接尚未就绪。"
        case .invalidDirectory: "工作台 MCP 套接字目录的所有者或权限不正确。"
        case .oversized: "MCP 消息超出大小限制。"
        }
    }
}

enum AgentSocket {
    static let path = "/tmp/codex-api-workbench-\(geteuid())/mcp.sock"
    static let maxFrame = 512 * 1024

    static func validateDirectory(for path: String, create: Bool) throws {
        let directory = (path as NSString).deletingLastPathComponent
        if create, mkdir(directory, 0o700) != 0, errno != EEXIST { throw systemError() }
        var info = stat()
        if lstat(directory, &info) != 0 {
            if errno == ENOENT { throw AgentSocketError.unavailable }
            throw systemError()
        }
        guard info.st_mode & S_IFMT == S_IFDIR, info.st_mode & 0o777 == 0o700, info.st_uid == geteuid() else {
            throw AgentSocketError.invalidDirectory
        }
    }

    static func address(_ path: String) throws -> sockaddr_un {
        let encoded = path.utf8CString
        var address = sockaddr_un()
        guard encoded.count <= MemoryLayout.size(ofValue: address.sun_path) else {
            throw WorkbenchError("MCP 套接字路径过长。")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(2 + encoded.count)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            encoded.withUnsafeBytes { destination.copyBytes(from: $0) }
        }
        return address
    }

    static func configure(_ fd: Int32, seconds: Int) {
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags & ~O_NONBLOCK) }
        var enabled: Int32 = 1
        var timeout = timeval(tv_sec: seconds, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }

    static func peerIsLocalUser(_ fd: Int32) -> Bool {
        var user: uid_t = 0
        var group: gid_t = 0
        return getpeereid(fd, &user, &group) == 0 && user == geteuid()
    }

    static func connect(to path: String) throws -> Int32 {
        try validateDirectory(for: path, create: false)
        var address = try address(path)
        let length = socklen_t(address.sun_len)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw systemError() }
        configure(fd, seconds: 40)
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, length) }
        }
        guard result == 0 else {
            let code = errno
            Darwin.close(fd)
            if code == ENOENT || code == ECONNREFUSED { throw AgentSocketError.unavailable }
            throw systemError(code)
        }
        guard peerIsLocalUser(fd) else {
            Darwin.close(fd)
            throw WorkbenchError("MCP 服务进程不属于当前用户。")
        }
        return fd
    }

    static func send(_ object: RPCObject, to fd: Int32) throws {
        var data = try JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes])
        guard data.count <= maxFrame else { throw AgentSocketError.oversized }
        data.append(10)
        try data.withUnsafeBytes { bytes in
            guard let address = bytes.baseAddress else { return }
            var written = 0
            while written < bytes.count {
                let count = Darwin.write(fd, address.advanced(by: written), bytes.count - written)
                if count < 0, errno == EINTR { continue }
                guard count > 0 else { throw systemError() }
                written += count
            }
        }
    }

    static func systemError(_ code: Int32 = errno) -> NSError {
        NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

final class AgentFrameReader {
    private let fd: Int32
    private var buffered = Data()
    private var chunk = [UInt8](repeating: 0, count: 16 * 1024)

    init(fd: Int32) { self.fd = fd }

    func next() throws -> Data? {
        while true {
            if let end = buffered.firstIndex(of: 10) {
                let frame = Data(buffered[..<end])
                buffered.removeSubrange(...end)
                guard frame.count <= AgentSocket.maxFrame else { throw AgentSocketError.oversized }
                return frame
            }
            guard buffered.count <= AgentSocket.maxFrame else { throw AgentSocketError.oversized }
            let count = chunk.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count >= 0 else { throw AgentSocket.systemError() }
            if count == 0 {
                guard buffered.isEmpty else { throw WorkbenchError("MCP 消息缺少结束换行。") }
                return nil
            }
            buffered.append(contentsOf: chunk.prefix(count))
        }
    }
}

// The listener and connection queues own their descriptors. The handler runs on the main actor.
final class AgentSocketServer: @unchecked Sendable {
    typealias Handler = @MainActor @Sendable (_ name: String, _ arguments: RPCObject) async throws -> RPCObject

    private static let workers = DispatchQueue(
        label: "api-workbench.mcp.connections", qos: .utility, attributes: .concurrent)
    private let slots = DispatchSemaphore(value: 32)
    private let source: DispatchSourceRead
    private let handle: Handler

    init(path: String = AgentSocket.path, handle: @escaping Handler) throws {
        self.handle = handle
        try AgentSocket.validateDirectory(for: path, create: true)
        let lockPath = (path as NSString).deletingLastPathComponent + "/server.lock"
        let lock = Darwin.open(lockPath, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else { throw AgentSocket.systemError() }
        do {
            var info = stat()
            guard fstat(lock, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_uid == geteuid(),
                info.st_mode & 0o777 == 0o600
            else { throw AgentSocketError.invalidDirectory }
            guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw AgentSocket.systemError() }
            let fd = try Self.listen(path)
            source = DispatchSource.makeReadSource(
                fileDescriptor: fd,
                queue: DispatchQueue(label: "api-workbench.mcp.listener", qos: .utility))
            source.setCancelHandler {
                Darwin.close(fd)
                unlink(path)
                Darwin.close(lock)
            }
            source.setEventHandler { [weak self] in self?.acceptConnections(on: fd) }
            source.resume()
        } catch {
            Darwin.close(lock)
            throw error
        }
    }

    func stop() { source.cancel() }
    deinit { source.cancel() }

    private static func listen(_ path: String) throws -> Int32 {
        var address = try AgentSocket.address(path)
        let length = socklen_t(address.sun_len)
        var current = stat()
        if lstat(path, &current) == 0 {
            guard current.st_uid == geteuid(), current.st_mode & S_IFMT == S_IFSOCK else {
                throw AgentSocketError.invalidDirectory
            }
            guard unlink(path) == 0 else { throw AgentSocket.systemError() }
        } else if errno != ENOENT {
            throw AgentSocket.systemError()
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw AgentSocket.systemError() }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, length) }
        }
        guard bound == 0, chmod(path, 0o600) == 0, fcntl(fd, F_SETFL, O_NONBLOCK) == 0,
            fcntl(fd, F_SETFD, FD_CLOEXEC) == 0, Darwin.listen(fd, 16) == 0
        else {
            let failure = AgentSocket.systemError()
            Darwin.close(fd)
            if bound == 0 { unlink(path) }
            throw failure
        }
        return fd
    }

    private func acceptConnections(on listener: Int32) {
        while !source.isCancelled {
            let fd = accept(listener, nil, nil)
            if fd < 0, errno == EINTR { continue }
            guard fd >= 0 else { return }
            AgentSocket.configure(fd, seconds: 8)
            guard AgentSocket.peerIsLocalUser(fd), slots.wait(timeout: .now()) == .success else {
                Darwin.close(fd)
                continue
            }
            Self.workers.async { [self] in
                do {
                    guard let line = try AgentFrameReader(fd: fd).next(),
                        let message = try JSONSerialization.jsonObject(with: line) as? RPCObject,
                        let name = message["name"] as? String, let arguments = message["arguments"] as? RPCObject
                    else {
                        throw WorkbenchError("无效的工作台 MCP 请求。")
                    }
                    Task { @MainActor in
                        let reply: RPCObject
                        do { reply = ["result": try await handle(name, arguments)] } catch {
                            reply = ["error": redact(error.localizedDescription)]
                        }
                        Self.workers.async { [self] in finish(reply, fd: fd) }
                    }
                } catch {
                    finish(["error": "无法读取工作台 MCP 请求。"], fd: fd)
                }
            }
        }
    }

    private func finish(_ reply: RPCObject, fd: Int32) {
        defer {
            Darwin.close(fd)
            slots.signal()
        }
        try? AgentSocket.send(reply, to: fd)
    }
}
