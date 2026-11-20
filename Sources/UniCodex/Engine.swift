import Darwin
import Foundation

typealias RPCObject = [String: Any]

struct WorkbenchError: LocalizedError {
    let errorDescription: String?

    init(_ message: String) {
        errorDescription = message
    }
}

struct EngineRequestError: LocalizedError {
    let code: Int?
    let message: String
    var errorDescription: String? { message }
}

func redact(_ text: String) -> String {
    text.replacingOccurrences(
        of: #"\b(?:sk-[A-Za-z0-9_\-]{6,}|AQ\.[A-Za-z0-9_\-]{20,}|AIza[A-Za-z0-9_\-]{35})"#,
        with: "[API Key]",
        options: .regularExpression
    )
}

struct EnginePaths {
    let codexHome: URL
    let credentialFile: URL
    let binary: URL
    let endpoint: String
    var modelCatalog: URL? = nil
    var providerTestEndpoints: [ProviderKind: String] = [:]

    static var local: EnginePaths {
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)
        let home = base.appendingPathComponent("Codex API Workbench", isDirectory: true)
        return EnginePaths(
            codexHome: home,
            credentialFile: base.appendingPathComponent("Codex-API/auth.json"),
            binary: CodexEngineFiles.installed(in: home)?.binary ?? CodexEngineFiles.bundled,
            endpoint: "https://api.openai.com/v1",
            modelCatalog: Bundle.main.url(forResource: "CodexModels", withExtension: "json")
        )
    }

    static let defaultModelID = "gpt-6.1-sol"
    var state: URL { codexHome.appendingPathComponent("state", isDirectory: true) }
    var workspace: URL { codexHome.appendingPathComponent("workspace", isDirectory: true) }

    func prepare() throws {
        let fm = FileManager.default
        for directory in [codexHome, state, workspace] {
            let info = try? directory.resourceValues(forKeys: [.isSymbolicLinkKey])
            guard info?.isSymbolicLink != true else {
                throw WorkbenchError("独立运行目录指向了其他位置，请检查「\(directory.path)」。")
            }
            try fm.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700])
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        }
        guard fm.isExecutableFile(atPath: binary.path) else {
            throw WorkbenchError(UIStrings.current.text("error.engine_missing"))
        }
    }

    func credential() throws -> String {
        let fm = FileManager.default
        guard let attributes = try? fm.attributesOfItem(atPath: credentialFile.path),
            attributes[.type] as? FileAttributeType == .typeRegular,
            let mode = attributes[.posixPermissions] as? NSNumber,
            mode.intValue & 0o077 == 0,
            let data = try? Data(contentsOf: credentialFile),
            let saved = try? JSONSerialization.jsonObject(with: data) as? RPCObject,
            saved["auth_mode"] as? String == "apikey",
            saved["tokens"] == nil || saved["tokens"] is NSNull,
            let key = saved["OPENAI_API_KEY"] as? String,
            key.hasPrefix("sk-"), !key.contains(where: \.isWhitespace)
        else {
            throw WorkbenchError(UIStrings.current.text("error.original_key"))
        }
        return key
    }

    func availableAPIModelIDs(using key: String) async throws -> Set<String> {
        guard let url = URL(string: endpoint)?.appendingPathComponent("models") else {
            throw WorkbenchError("无法识别 OpenAI API 地址。")
        }
        struct ModelList: Decodable {
            struct Model: Decodable { let id: String }
            let data: [Model]
        }
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = 6
        settings.timeoutIntervalForResource = 8
        let session = URLSession(configuration: settings)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url)
        request.setValue("Bearer " + key, forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw WorkbenchError("无法读取该 API Key 的模型目录。")
        }
        return Set(try JSONDecoder().decode(ModelList.self, from: data).data.map(\.id))
    }

    func configure(_ process: Process, provider: DirectEngineProvider? = nil) throws {
        var environment = ProcessInfo.processInfo.environment.filter {
            let name = $0.key
            if name == "GOOGLE_API_KEY" || name == "GEMINI_API_KEY" { return false }
            return !["CODEX_", "OPENAI_", "KIMI_", "MOONSHOT_", "DEEPSEEK_", DirectEngineProvider.keyName]
                .contains { name.hasPrefix($0) }
        }
        environment["CODEX_HOME"] = codexHome.path
        let preferredPath = [
            "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin",
        ]
        environment["PATH"] = preferredPath.joined(separator: ":") + ":" + (environment["PATH"] ?? "")
        process.executableURL = binary
        process.currentDirectoryURL = workspace
        if let key = provider?.key { environment[DirectEngineProvider.keyName] = key }
        if provider?.transport != nil {
            let noProxy = environment["NO_PROXY"] ?? environment["no_proxy"]
            let localOnly = [noProxy, "127.0.0.1", "localhost"].compactMap { $0 }.joined(separator: ",")
            environment["NO_PROXY"] = localOnly
            environment["no_proxy"] = localOnly
        }
        process.environment = environment
        var arguments = [
            "app-server", "--listen", "stdio://",
            "-c", "cli_auth_credentials_store=\"ephemeral\"",
            "-c", "forced_login_method=\"api\"",
            "-c", "model_provider=" + (try tomlString(provider?.id ?? "openai")),
            "-c", "openai_base_url=" + (try tomlString(endpoint)),
            "-c", "sqlite_home=" + (try tomlString(state.path)),
        ]
        if let provider {
            let config = "model_providers.\(provider.id)"
            arguments += [
                "-c", "\(config).name=" + (try tomlString(provider.name)),
                "-c", "\(config).base_url=" + (try tomlString(provider.endpoint)),
                "-c", "\(config).wire_api=\"responses\"",
                "-c", "\(config).env_key=\"\(DirectEngineProvider.keyName)\"",
                "-c", "\(config).supports_websockets=false",
                "-c", "shell_environment_policy.exclude=[\"\(DirectEngineProvider.keyName)\"]",
                "-c", "model=" + (try tomlString(provider.modelID)),
            ]
            if provider.kind != .openAI {
                arguments += ["-c", "web_search=\"disabled\""]
            }
        }
        if let modelCatalog = provider?.catalog ?? modelCatalog {
            arguments += ["-c", "model_catalog_json=" + (try tomlString(modelCatalog.path))]
        }
        process.arguments = arguments
    }

    private func tomlString(_ value: String) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

struct DirectEngineProvider {
    static let keyName = "WORKBENCH_PROVIDER_TOKEN"
    let id: String
    let name: String
    let kind: ProviderKind
    var endpoint: String
    let modelID: String
    let catalog: URL?
    var key: String?
    var transport: GeminiTransport? = nil
}

private struct EngineFrameBuffer {
    private var buffer = Data()
    var isOverLimit: Bool { buffer.count > 32 * 1024 * 1024 }

    mutating func read(_ bytes: Data) -> [RPCObject] {
        buffer.append(bytes)
        var frames: [RPCObject] = []
        var start = buffer.startIndex
        while let end = buffer[start...].firstIndex(of: 10) {
            if let frame = try? JSONSerialization.jsonObject(with: buffer[start..<end]) as? RPCObject {
                frames.append(frame)
            }
            start = end + 1
        }
        if start > buffer.startIndex { buffer.removeSubrange(..<start) }
        return frames
    }
}

@MainActor
final class CodexConnection {
    var onEvent: ((String, RPCObject) -> Void)?
    var onRequest: ((Any, String, RPCObject) -> Void)?
    var onDisconnect: ((String) -> Void)?

    private let process: Process
    private let providerSecret: String?
    private let transport: GeminiTransport?
    private let input: FileHandle
    private struct PendingRequest {
        let completion: CheckedContinuation<RPCObject, Error>
        let deadline: Task<Void, Never>
    }

    private let writer = DispatchQueue(label: "api-workbench.engine-write", qos: .userInitiated)
    private var pending: [Int: PendingRequest] = [:]
    private var nextID = 0
    private var stopped = false
    var attachedThreads = Set<String>()
    var isOpen: Bool { !stopped && process.isRunning }

    init(paths: EnginePaths, provider: DirectEngineProvider? = nil) throws {
        providerSecret = provider?.key
        transport = provider?.transport
        let stdin = Pipe()
        let stdout = Pipe()
        let appServer = Process()
        try paths.configure(appServer, provider: provider)
        appServer.standardInput = stdin
        appServer.standardOutput = stdout
        appServer.standardError = FileHandle.nullDevice
        input = stdin.fileHandleForWriting
        process = appServer
        try process.run()

        let reader = stdout.fileHandleForReading
        DispatchQueue(label: "api-workbench.engine-read", qos: .userInitiated).async { [weak self] in
            var buffer = EngineFrameBuffer()
            while true {
                let data = reader.availableData
                if data.isEmpty { break }
                let frames = buffer.read(data)
                if !frames.isEmpty {
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.stopped else { return }
                        for frame in frames { self.receive(frame) }
                    }
                }
                if buffer.isOverLimit {
                    DispatchQueue.main.async { [weak self] in self?.finish("Codex 引擎返回的数据过大。") }
                    return
                }
            }
            DispatchQueue.main.async { [weak self] in
                self?.finish(UIStrings.current.text("error.engine_disconnected"))
            }
        }
    }

    func request(_ method: String, _ params: RPCObject = [:], timeout: UInt64 = 30) async throws -> RPCObject {
        nextID += 1
        let id = nextID
        return try await withCheckedThrowingContinuation { continuation in
            do {
                try write(["method": method, "params": params, "id": id])
            } catch {
                continuation.resume(throwing: error)
                return
            }
            let deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
                self?.pending.removeValue(forKey: id)?
                    .completion.resume(throwing: WorkbenchError("Codex 引擎响应超时（\(method)）。"))
            }
            pending[id] = PendingRequest(completion: continuation, deadline: deadline)
        }
    }

    func safeMessage(_ message: String) -> String {
        guard let providerSecret, !providerSecret.isEmpty else { return redact(message) }
        return redact(message.replacingOccurrences(of: providerSecret, with: "[API Key]"))
    }

    func notify(_ method: String) throws {
        try write(["method": method, "params": RPCObject()])
    }

    func reply(to id: Any, result: RPCObject) throws {
        try write(["id": id, "result": result])
    }

    func unsupported(_ id: Any, method: String) {
        try? write(["id": id, "error": ["code": -32601, "message": "Unsupported client request: \(method)"]])
    }

    func stop() {
        onDisconnect = nil
        finish(UIStrings.current.text("error.engine_closed"))
    }

    private func write(_ message: RPCObject) throws {
        guard !stopped, process.isRunning else {
            throw WorkbenchError("Codex 引擎未运行。")
        }
        var encoded = try JSONSerialization.data(withJSONObject: message)
        encoded.append(10)
        let data = encoded
        let handle = input
        writer.async { [weak self] in
            do { try handle.write(contentsOf: data) } catch {
                DispatchQueue.main.async { [weak self] in
                    self?.finish("无法向 Codex 引擎发送请求。请重新连接。")
                }
            }
        }
    }

    private func receive(_ frame: RPCObject) {
        if let method = frame["method"] as? String {
            let params = frame["params"] as? RPCObject ?? [:]
            if let id = frame["id"] {
                onRequest?(id, method, params)
            } else {
                onEvent?(method, params)
            }
        } else if let id = frame["id"] as? Int, let request = pending.removeValue(forKey: id) {
            request.deadline.cancel()
            let completion = request.completion
            if let failure = frame["error"] as? RPCObject {
                let message = failure["message"] as? String ?? "Codex 引擎拒绝了请求。"
                completion.resume(
                    throwing: EngineRequestError(code: failure["code"] as? Int, message: safeMessage(message)))
            } else if let result = frame["result"] as? RPCObject {
                completion.resume(returning: result)
            } else {
                completion.resume(throwing: WorkbenchError("Codex 引擎返回了无法识别的数据。"))
            }
        }
    }

    private func finish(_ explanation: String) {
        guard !stopped else { return }
        stopped = true
        transport?.close()
        if process.isRunning { process.terminate() }
        let handle = input
        writer.async { try? handle.close() }
        let waiting = pending
        pending.removeAll()
        for request in waiting.values {
            request.deadline.cancel()
            request.completion.resume(throwing: WorkbenchError(explanation))
        }
        onDisconnect?(explanation)
    }
}
