import CryptoKit
import Darwin
import Foundation
import Observation

enum CodexEngineFiles {
    static let bundled = URL(
        fileURLWithPath:
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")

    private static let stagingPrefix = ".unicodex-update-"
    private static let legacyStagingPrefix = ".update-"
    private static let fileKeys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]

    private static func directory(in home: URL) -> URL { home.appendingPathComponent("engine", isDirectory: true) }
    private static func receipt(in home: URL) -> URL { directory(in: home).appendingPathComponent("selected-version") }
    private static func program(_ version: ReleaseVersion, in home: URL) -> URL {
        directory(in: home).appendingPathComponent("codex-" + version.description)
    }

    static func installed(in home: URL) -> (version: ReleaseVersion, binary: URL)? {
        let root = directory(in: home)
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
            (try? receipt(in: home).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
            let value = try? String(contentsOf: receipt(in: home), encoding: .utf8),
            let release = ReleaseVersion(value), release.isStable
        else { return nil }
        let binary = program(release, in: home)
        guard let info = try? binary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            info.isRegularFile == true, info.isSymbolicLink == false,
            FileManager.default.isExecutableFile(atPath: binary.path)
        else { return nil }
        return (release, binary)
    }

    static func acquireUpdateLock(in home: URL) throws -> FileHandle? {
        let root = directory(in: home)
        for folder in [home, root] {
            guard (try? folder.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
                throw CocoaError(.fileWriteInvalidFileName)
            }
        }
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let lock = root.appendingPathComponent(".update-lock")
        let descriptor = open(lock.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            throw CocoaError(.fileWriteInvalidFileName)
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return handle }
        if errno == EWOULDBLOCK { return nil }
        throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
    }

    static func prepareDownload(in home: URL) throws -> URL {
        let staging = directory(in: home)
            .appendingPathComponent(stagingPrefix + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
        return staging
    }

    static func publish(_ candidate: URL, version: ReleaseVersion, in home: URL) throws {
        guard version.isStable else { throw WorkbenchError("只能安装稳定版本。") }
        if let selected = installed(in: home), selected.version >= version { return }
        let destination = program(version, in: home)
        if FileManager.default.fileExists(atPath: destination.path) {
            let info = try destination.resourceValues(forKeys: fileKeys)
            guard info.isRegularFile == true, info.isSymbolicLink == false,
                try digest(candidate) == digest(destination)
            else {
                throw WorkbenchError("已有同版本引擎的内容不匹配。")
            }
        } else {
            try FileManager.default.moveItem(at: candidate, to: destination)
        }
        try Data(version.description.utf8).write(to: receipt(in: home), options: .atomic)
    }

    // Call while holding the update lock, before staging or after the staging directory is closed.
    static func retireInactive(in home: URL, active: URL) {
        let root = directory(in: home)
        let keys = fileKeys.union([.contentModificationDateKey])
        guard let snapshot = try? run("/bin/ps", ["-axww", "-o", "comm="]),
            let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)),
            let resolved = realpath(root.path, nil)
        else { return }
        defer { free(resolved) }
        let roots = Set([root.path, String(cString: resolved)])
        let running = Set(
            snapshot.split(whereSeparator: \.isNewline).compactMap { line -> String? in
                let process = line.trimmingCharacters(in: .whitespaces)
                guard let directory = roots.first(where: { process.hasPrefix($0 + "/") }) else { return nil }
                return process.dropFirst(directory.count + 1).split(separator: "/", maxSplits: 1).first.map(String.init)
            })
        let selected = installed(in: home)?.binary.lastPathComponent
        for file in files {
            let name = file.lastPathComponent
            guard name != active.lastPathComponent, name != selected,
                !running.contains(name), let info = try? file.resourceValues(forKeys: keys),
                info.isSymbolicLink == false
            else { continue }
            if info.isRegularFile == true, selected != nil, name.hasPrefix("codex-"),
                ReleaseVersion(String(name.dropFirst("codex-".count)))?.isStable == true
            {
                try? FileManager.default.removeItem(at: file)
            } else if info.isDirectory == true, isAbandonedDownload(file, modified: info.contentModificationDate) {
                try? FileManager.default.removeItem(at: file)
            }
        }
    }

    private static func isAbandonedDownload(_ directory: URL, modified: Date?) -> Bool {
        let name = directory.lastPathComponent
        let prefix = name.hasPrefix(stagingPrefix) ? stagingPrefix : legacyStagingPrefix
        guard name.hasPrefix(prefix), UUID(uuidString: String(name.dropFirst(prefix.count))) != nil else {
            return false
        }
        // Earlier versions staged downloads without the lock. Give those downloads time to finish.
        if prefix == legacyStagingPrefix {
            guard let modified, Date().timeIntervalSince(modified) > 3600 else { return false }
        }
        guard
            let items = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: Array(fileKeys))
        else { return false }
        return items.allSatisfy { item in
            guard let info = try? item.resourceValues(forKeys: fileKeys), info.isSymbolicLink == false else {
                return false
            }
            switch item.lastPathComponent {
            case "codex", "engine.tar.gz": return info.isRegularFile == true
            case "probe": return info.isDirectory == true
            default: return false
            }
        }
    }

    static func version(of program: URL) throws -> ReleaseVersion {
        let output = try run(program.path, ["--version"])
        guard let token = output.split(whereSeparator: \.isWhitespace).dropFirst().first,
            let version = ReleaseVersion(String(token))
        else {
            throw WorkbenchError("无法识别 Codex 引擎版本。")
        }
        return version
    }

    static func digest(_ file: URL) throws -> String {
        try digest(file, using: SHA256.self).map { String(format: "%02x", $0) }.joined()
    }

    static func digest<H: HashFunction>(_ file: URL, using algorithm: H.Type) throws -> H.Digest {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = H()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize()
    }

    static func run(_ program: String, _ arguments: [String], outputFile: URL? = nil, timeout: TimeInterval = 12) throws
        -> String
    {
        let process = Process()
        let pipe = Pipe()
        let target: FileHandle?
        if let outputFile {
            guard
                FileManager.default.createFile(
                    atPath: outputFile.path, contents: nil,
                    attributes: [.posixPermissions: 0o600])
            else {
                throw WorkbenchError("无法创建引擎临时文件。")
            }
            target = try FileHandle(forWritingTo: outputFile)
        } else {
            target = nil
        }
        defer { try? target?.close() }
        process.executableURL = URL(fileURLWithPath: program)
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = target.map { $0 as Any } ?? pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let deadline = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout, execute: deadline)
        defer { deadline.cancel() }
        let data = target == nil ? pipe.fileHandleForReading.readDataToEndOfFile() : Data()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw WorkbenchError("无法验证引擎文件（\(URL(fileURLWithPath: program).lastPathComponent)）。")
        }
        return String(decoding: data, as: UTF8.self)
    }
}

@Observable @MainActor
final class CodexEngineUpdate {
    private let paths: EnginePaths
    private(set) var activeVersion: ReleaseVersion?
    private(set) var latestVersion: ReleaseVersion?
    private(set) var pendingVersion: ReleaseVersion?
    private(set) var lastChecked: Date?
    private var statusKey = "engine.status_version"
    private var statusVersion: String?
    private var statusError: String?
    private(set) var working = false
    private(set) var failed = false

    init(paths: EnginePaths) { self.paths = paths }

    func status(using strings: UIStrings) -> String {
        if let statusError { return statusError }
        if let statusVersion { return strings.text(statusKey, statusVersion) }
        return strings.text(statusKey)
    }

    private func show(_ key: String, version: ReleaseVersion? = nil) {
        statusKey = key
        statusVersion = version?.description
        statusError = nil
    }

    func monitor() async {
        while !Task.isCancelled {
            await check()
            do { try await Task.sleep(for: .seconds(86_400)) } catch { break }
        }
    }

    func check(using session: URLSession = CodexEngineRelease.session) async {
        guard !working else { return }
        working = true
        failed = false
        defer { working = false }
        do {
            let paths = self.paths
            show("engine.status_check")
            guard let lock = try CodexEngineFiles.acquireUpdateLock(in: paths.codexHome) else {
                show("engine.status_busy")
                return
            }
            defer { try? lock.close() }
            let needsVersion = activeVersion == nil
            let version = await Task.detached(priority: .utility) {
                CodexEngineFiles.retireInactive(in: paths.codexHome, active: paths.binary)
                return needsVersion ? try? CodexEngineFiles.version(of: paths.binary) : nil
            }.value
            if let version { activeVersion = version }
            let installed = CodexEngineFiles.installed(in: paths.codexHome)
            pendingVersion = installed.flatMap { $0.binary == paths.binary ? nil : $0.version }
            let release = try await CodexEngineRelease.latest(using: session)
            latestVersion = release.version
            lastChecked = Date()
            let available = [activeVersion, installed?.version].compactMap { $0 }.max()
            if let available, release.version <= available {
                if let pendingVersion {
                    show("engine.status_next", version: pendingVersion)
                } else {
                    show("engine.status_current")
                }
                return
            }
            show("engine.status_download", version: release.version)
            try await install(release, using: session)
            await Task.detached(priority: .utility) {
                CodexEngineFiles.retireInactive(in: paths.codexHome, active: paths.binary)
            }.value
            pendingVersion = release.version
            show("engine.status_verified", version: release.version)
        } catch is CancellationError {
            show("engine.status_cancel")
        } catch {
            failed = true
            statusError = error.localizedDescription
        }
    }

    private func install(_ release: CodexEngineRelease, using session: URLSession) async throws {
        let paths = self.paths
        let staging = try CodexEngineFiles.prepareDownload(in: paths.codexHome)
        defer { try? FileManager.default.removeItem(at: staging) }
        let candidate = try await release.download(into: staging, using: session)
        try Task.checkCancellation()
        try await verifyAppServer(candidate, in: staging)
        try Task.checkCancellation()
        try await Task.detached(priority: .utility) {
            try CodexEngineFiles.publish(candidate, version: release.version, in: paths.codexHome)
        }.value
    }

    private func verifyAppServer(_ binary: URL, in staging: URL) async throws {
        let probe = EnginePaths(
            codexHome: staging.appendingPathComponent("probe", isDirectory: true),
            credentialFile: staging.appendingPathComponent("no-key"),
            binary: binary, endpoint: "http://127.0.0.1:1", modelCatalog: paths.modelCatalog)
        try probe.prepare()
        let server = try CodexConnection(paths: probe)
        defer { server.stop() }
        try await ProviderEnginePool.initialize(server, paths: probe)
        _ = try await server.request("model/list", timeout: 10)
        _ = try await server.request("thread/list", ["limit": 1], timeout: 10)
        let absent = "00000000-0000-7000-8000-000000000000"
        var history = TranscriptArchiveBuilder()
        do {
            try await TranscriptHistoryReader.read(server, threadID: absent, namespace: nil, into: &history)
        } catch let error as EngineRequestError where error.code != -32601 {
            // The fresh probe home has no saved threads.
        }
        let probes: [(String, RPCObject)] = [
            ("thread/inject_items", ["threadId": absent, "items": [] as [RPCObject]]),
            ("thread/delete", ["threadId": absent]),
        ]
        for (method, parameters) in probes {
            do {
                _ = try await server.request(method, parameters, timeout: 8)
            } catch let error as EngineRequestError where error.code != -32601 {
                continue
            }
        }
    }
}
