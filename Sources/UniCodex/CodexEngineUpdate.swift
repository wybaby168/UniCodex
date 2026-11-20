import CryptoKit
import Foundation
import Observation

struct CodexEngineVersion: Comparable, Codable, CustomStringConvertible {
    let description: String

    init?(_ value: String) {
        guard
            value.range(
                of: #"^[0-9]{1,6}\.[0-9]{1,6}\.[0-9]{1,6}(?:-[a-zA-Z0-9.]+)?$"#,
                options: .regularExpression) != nil
        else { return nil }
        description = value
    }

    var isStable: Bool { !description.contains("-") }

    static func < (left: Self, right: Self) -> Bool {
        let lhs = left.description.split(separator: "-", maxSplits: 1)
        let rhs = right.description.split(separator: "-", maxSplits: 1)
        let leftCore = lhs[0].split(separator: ".").compactMap { Int($0) }
        let rightCore = rhs[0].split(separator: ".").compactMap { Int($0) }
        if leftCore != rightCore { return leftCore.lexicographicallyPrecedes(rightCore) }
        if lhs.count != rhs.count { return lhs.count > rhs.count }
        guard lhs.count > 1 else { return false }
        return lhs[1].compare(rhs[1], options: .numeric) == .orderedAscending
    }
}

struct CodexEngineRelease {
    private struct Listing: Decodable {
        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }
    private struct Asset: Decodable {
        let name: String
        let digest: String?
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name, digest
            case browserDownloadURL = "browser_download_url"
        }
    }

    private static let origin = URL(string: "https://releases.openai.com/codex")!
    static let programName: String = {
        #if arch(arm64)
            "codex-aarch64-apple-darwin"
        #else
            "codex-x86_64-apple-darwin"
        #endif
    }()
    let version: CodexEngineVersion
    let url: URL
    let sha256: String

    static func latest() async throws -> Self {
        let (data, response) = try await session.data(
            for: URLRequest(url: origin.appendingPathComponent("channels/latest"), timeoutInterval: 18))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WorkbenchError("暂时无法读取 OpenAI 的稳定版本目录。")
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let filename = programName + ".tar.gz"
        guard listing.tagName.hasPrefix("rust-v"),
            let version = CodexEngineVersion(String(listing.tagName.dropFirst(6))),
            version.isStable, let asset = listing.assets.first(where: { $0.name == filename }),
            let digest = asset.digest, digest.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil
        else {
            throw WorkbenchError("OpenAI 的版本目录中没有此 Mac 的稳定引擎。")
        }
        let url = origin.appendingPathComponent("releases").appendingPathComponent(version.description)
            .appendingPathComponent(filename)
        guard url.absoluteString == asset.browserDownloadURL else {
            throw WorkbenchError("引擎下载地址与 OpenAI 版本目录不符。")
        }
        return Self(version: version, url: url, sha256: String(digest.dropFirst("sha256:".count)))
    }

    func download(into scratch: URL) async throws -> URL {
        let archive = scratch.appendingPathComponent("engine.tar.gz")
        let (downloaded, response) = try await Self.session.download(from: url)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WorkbenchError("OpenAI 的引擎下载暂不可用。")
        }
        try FileManager.default.moveItem(at: downloaded, to: archive)
        let expected = sha256
        return try await Task.detached(priority: .utility) {
            let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard (1...300 * 1024 * 1024).contains(size), try CodexEngineFiles.digest(archive) == expected else {
                throw WorkbenchError("下载文件的 SHA-256 校验失败。")
            }
            let lines = try CodexEngineFiles.run("/usr/bin/tar", ["-tzf", archive.path])
                .split(whereSeparator: \.isNewline).map(String.init)
            guard lines.count == 1, let entry = lines.first,
                entry == Self.programName || entry == "./" + Self.programName
            else {
                throw WorkbenchError("OpenAI 引擎包的内容结构不匹配。")
            }
            let program = scratch.appendingPathComponent("codex")
            _ = try CodexEngineFiles.run(
                "/usr/bin/tar", ["-xOzf", archive.path, entry], outputFile: program, timeout: 60)
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
            _ = try CodexEngineFiles.run("/usr/bin/codesign", ["--verify", "--strict", program.path])
            guard try CodexEngineFiles.version(of: program) == version else {
                throw WorkbenchError("引擎可执行文件的版本与发布目录不符。")
            }
            return program
        }.value
    }

    private final class OfficialDownloads: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            let url = request.url
            completionHandler(url?.scheme == "https" && url?.host == "releases.openai.com" ? request : nil)
        }
    }

    private static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 35
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: OfficialDownloads(), delegateQueue: nil)
    }()
}

enum CodexEngineFiles {
    static let bundled = URL(
        fileURLWithPath:
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex")

    private static func directory(in home: URL) -> URL { home.appendingPathComponent("engine", isDirectory: true) }
    private static func receipt(in home: URL) -> URL { directory(in: home).appendingPathComponent("selected-version") }
    private static func program(_ version: CodexEngineVersion, in home: URL) -> URL {
        directory(in: home).appendingPathComponent("codex-" + version.description)
    }

    static func installed(in home: URL) -> (version: CodexEngineVersion, binary: URL)? {
        let root = directory(in: home)
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
            (try? receipt(in: home).resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
            let value = try? String(contentsOf: receipt(in: home), encoding: .utf8),
            let release = CodexEngineVersion(value), release.isStable
        else { return nil }
        let binary = program(release, in: home)
        guard let info = try? binary.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
            info.isRegularFile == true, info.isSymbolicLink == false,
            FileManager.default.isExecutableFile(atPath: binary.path)
        else { return nil }
        return (release, binary)
    }

    static func prepareDownload(in home: URL) throws -> URL {
        let root = directory(in: home)
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw WorkbenchError("独立引擎目录指向了其他位置。")
        }
        let staging = root.appendingPathComponent(".update-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(
            at: staging, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        return staging
    }

    static func publish(_ candidate: URL, version: CodexEngineVersion, in home: URL) throws {
        guard version.isStable else { throw WorkbenchError("只能安装稳定版本。") }
        if let selected = installed(in: home), selected.version >= version { return }
        let destination = program(version, in: home)
        if FileManager.default.fileExists(atPath: destination.path) {
            guard try digest(candidate) == digest(destination),
                (try? destination.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false
            else {
                throw WorkbenchError("已有同版本引擎的内容不匹配。")
            }
        } else {
            try FileManager.default.moveItem(at: candidate, to: destination)
        }
        try Data(version.description.utf8).write(to: receipt(in: home), options: .atomic)
    }

    static func retireInactive(in home: URL, active: URL) {
        guard let selected = installed(in: home),
            let snapshot = try? run("/bin/ps", ["-axww", "-o", "comm="]),
            let files = try? FileManager.default.contentsOfDirectory(
                at: directory(in: home),
                includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        else { return }
        let running = Set(snapshot.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) })
        for file in files where file != active && file != selected.binary {
            guard file.lastPathComponent.hasPrefix("codex-"),
                CodexEngineVersion(String(file.lastPathComponent.dropFirst(6)))?.isStable == true,
                !running.contains(file.path),
                let info = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                info.isRegularFile == true, info.isSymbolicLink == false
            else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    static func version(of program: URL) throws -> CodexEngineVersion {
        let output = try run(program.path, ["--version"])
        guard let token = output.split(whereSeparator: \.isWhitespace).dropFirst().first,
            let version = CodexEngineVersion(String(token))
        else {
            throw WorkbenchError("无法识别 Codex 引擎版本。")
        }
        return version
    }

    static func digest(_ file: URL) throws -> String {
        let input = try FileHandle(forReadingFrom: file)
        defer { try? input.close() }
        var hash = SHA256()
        while let chunk = try input.read(upToCount: 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
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
    private(set) var activeVersion: CodexEngineVersion?
    private(set) var latestVersion: CodexEngineVersion?
    private(set) var pendingVersion: CodexEngineVersion?
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

    private func show(_ key: String, version: CodexEngineVersion? = nil) {
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

    func check() async {
        guard !working else { return }
        working = true
        failed = false
        defer { working = false }
        do {
            let paths = self.paths
            if activeVersion == nil {
                activeVersion = try? await Task.detached(priority: .utility) {
                    CodexEngineFiles.retireInactive(in: paths.codexHome, active: paths.binary)
                    return try CodexEngineFiles.version(of: paths.binary)
                }.value
            }
            show("engine.status_check")
            let release = try await CodexEngineRelease.latest()
            latestVersion = release.version
            lastChecked = Date()
            let installed = CodexEngineFiles.installed(in: paths.codexHome)
            pendingVersion = installed.flatMap { $0.binary == paths.binary ? nil : $0.version }
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
            let staging = try CodexEngineFiles.prepareDownload(in: paths.codexHome)
            defer { try? FileManager.default.removeItem(at: staging) }
            let candidate = try await release.download(into: staging)
            try Task.checkCancellation()
            try await verifyAppServer(candidate, in: staging)
            try await Task.detached(priority: .utility) {
                try CodexEngineFiles.publish(candidate, version: release.version, in: paths.codexHome)
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

    private func verifyAppServer(_ binary: URL, in staging: URL) async throws {
        let probe = EnginePaths(
            codexHome: staging.appendingPathComponent("probe"),
            credentialFile: staging.appendingPathComponent("no-key"),
            binary: binary, endpoint: "http://127.0.0.1:1", modelCatalog: paths.modelCatalog)
        try probe.prepare()
        let server = try CodexConnection(paths: probe)
        defer { server.stop() }
        try await ProviderEnginePool.initialize(server, paths: probe)
        _ = try await server.request("model/list", timeout: 10)
        _ = try await server.request("thread/list", ["limit": 1], timeout: 10)
        let absent: RPCObject = ["threadId": "00000000-0000-7000-8000-000000000000"]
        for method in ["thread/items/list", "thread/inject_items", "thread/delete"] {
            do { _ = try await server.request(method, absent, timeout: 8) } catch let error as EngineRequestError
                where error.code != -32601
            { continue } catch { throw WorkbenchError("新版引擎暂不支持工作台所需的接口（\(method)）。") }
        }
    }
}
