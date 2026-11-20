import CoreFoundation
import Darwin
import Foundation

struct WorkbenchMCPConfiguration {
    static let name = "codex_api_workbench"
    static let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.11"
    static let command = Bundle.main.executableURL?.path ?? "/Applications/UniCodex.app/Contents/MacOS/APIWorkbench"
    static let arguments = ["--mcp"]

    static var json: String {
        let config = ["mcpServers": [name: ["command": command, "args": arguments] as RPCObject]]
        let data = try? JSONSerialization.data(
            withJSONObject: config, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        return data.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }

    static var codexCommand: String {
        "codex mcp add \(name) -- '\(command.replacingOccurrences(of: "'", with: "'\\''"))' --mcp"
    }
}

final class AgentRPCClient {
    private let path: String
    private let launchBundle: URL?
    private let launchLock = NSLock()
    private var lastLaunchAttempt: ContinuousClock.Instant?

    init(path: String = AgentSocket.path, launchBundle: URL? = Bundle.main.bundleURL) {
        self.path = path
        self.launchBundle = launchBundle
    }

    func call(_ name: String, arguments: RPCObject) throws -> RPCObject {
        let socket = try connect()
        defer { Darwin.close(socket) }
        try AgentSocket.send(["name": name, "arguments": arguments], to: socket)
        guard let line = try AgentFrameReader(fd: socket).next(),
            let reply = try JSONSerialization.jsonObject(with: line) as? RPCObject
        else {
            throw WorkbenchError("工作台没有返回 MCP 结果。")
        }
        if let error = reply["error"] as? String { throw WorkbenchError(error) }
        guard let result = reply["result"] as? RPCObject else { throw WorkbenchError("工作台返回了无效结果。") }
        return result
    }

    private func connect() throws -> Int32 {
        do { return try AgentSocket.connect(to: path) } catch AgentSocketError.unavailable {
            guard let launchBundle, launchBundle.pathExtension == "app" else { throw AgentSocketError.unavailable }
            try launchLock.withLock {
                let now = ContinuousClock.now
                if let last = lastLaunchAttempt, last.duration(to: now) < .seconds(8) { return }
                lastLaunchAttempt = now
                let launch = Process()
                launch.executableURL = URL(fileURLWithPath: "/usr/bin/open")
                launch.arguments = ["-g", launchBundle.path, "--args", "--agent-launch"]
                launch.standardInput = FileHandle.nullDevice
                launch.standardOutput = FileHandle.nullDevice
                launch.standardError = FileHandle.nullDevice
                try launch.run()
                launch.waitUntilExit()
                guard launch.terminationStatus == 0 else { throw WorkbenchError("未能打开 Codex API 工作台。") }
            }
            let deadline = ContinuousClock.now + .seconds(10)
            while ContinuousClock.now < deadline {
                do { return try AgentSocket.connect(to: path) } catch AgentSocketError.unavailable {
                    Thread.sleep(forTimeInterval: 0.15)
                }
            }
            throw AgentSocketError.unavailable
        }
    }
}

final class AgentMCPStdio {
    private enum Era { case initial, legacy, modern }
    private static let modern = "2026-07-28"
    private static let legacy = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]
    private static let versionKey = "io.modelcontextprotocol/protocolVersion"
    private static let versions = [modern] + legacy
    private static let guidance =
        "Dispatch locally, then use task_status to wait or fetch a short answer. Approvals appear in Workbench."

    private let client: AgentRPCClient
    private let lock = NSLock()
    private let group = DispatchGroup()
    private var pending: [Data: Bool] = [:]
    private var era = Era.initial
    private var initialized = false

    init(client: AgentRPCClient = AgentRPCClient()) { self.client = client }

    func run() {
        signal(SIGPIPE, SIG_IGN)
        let reader = AgentFrameReader(fd: STDIN_FILENO)
        do {
            while let line = try reader.next() {
                guard let object = try? JSONSerialization.jsonObject(with: line) else {
                    send(error(-32700, "Parse error", id: NSNull()))
                    continue
                }
                receive(object as? RPCObject)
            }
        } catch {
            send(self.error(-32700, "Invalid MCP input", id: NSNull()))
        }
        _ = group.wait(timeout: .now() + 43)
    }

    private func receive(_ message: RPCObject?) {
        guard let message, message["jsonrpc"] as? String == "2.0", let method = message["method"] as? String else {
            send(error(-32600, "Invalid request", id: NSNull()))
            return
        }
        let params = message["params"] as? RPCObject ?? [:]
        if message["id"] == nil {
            receiveNotification(method, params: params)
            return
        }
        guard let id = message["id"], let encodedID = requestID(id) else {
            send(error(-32600, "Invalid request ID", id: NSNull()))
            return
        }
        guard message["params"] == nil || message["params"] is RPCObject else {
            send(error(-32602, "Expected an object for params", id: id))
            return
        }
        if era == .initial {
            if method == "initialize" {
                era = .legacy
                let offered = params["protocolVersion"] as? String
                let version = offered.flatMap { Self.legacy.contains($0) ? $0 : nil } ?? Self.legacy[0]
                send(
                    result(
                        [
                            "protocolVersion": version, "serverInfo": Self.serverInfo(),
                            "capabilities": ["tools": RPCObject()], "instructions": Self.guidance,
                        ], id: id))
                return
            }
            if method == "server/discover" || params["_meta"] != nil { era = .modern }
        }
        if era == .modern {
            let metadata = params["_meta"] as? RPCObject
            guard let version = metadata?[Self.versionKey] as? String else {
                send(error(-32602, "Missing protocol version metadata", id: id))
                return
            }
            guard version == Self.modern else {
                send(
                    error(
                        -32022, "Unsupported protocol version", id: id,
                        extra: ["requested": version, "supported": [Self.modern]]))
                return
            }
            if method == "server/discover" {
                send(
                    result(
                        [
                            "supportedVersions": Self.versions, "serverInfo": Self.serverInfo(),
                            "capabilities": ["tools": RPCObject()], "instructions": Self.guidance,
                        ], id: id))
                return
            }
        }
        if method == "ping" {
            send(result([:], id: id))
            return
        }
        guard era == .modern || initialized else {
            send(error(-32002, "Initialize the MCP connection first", id: id))
            return
        }
        switch method {
        case "tools/list":
            send(result(["tools": Self.tools], id: id))
        case "tools/call":
            guard let name = params["name"] as? String, Self.tools.contains(where: { $0["name"] as? String == name }),
                params["arguments"] == nil || params["arguments"] is RPCObject
            else {
                send(error(-32602, "Unknown tool or invalid arguments", id: id))
                return
            }
            let input = params["arguments"] as? RPCObject ?? [:]
            runTool(name, input: input, id: id, encodedID: encodedID)
        default:
            send(error(-32601, "Method not found", id: id))
        }
    }

    private func receiveNotification(_ method: String, params: RPCObject) {
        if era == .legacy, method == "notifications/initialized" { initialized = true }
        if method == "notifications/cancelled", let id = params["requestId"], let key = requestID(id) {
            lock.withLock { if pending[key] != nil { pending[key] = false } }
        }
    }

    private func runTool(_ name: String, input: RPCObject, id: Any, encodedID: Data) {
        let reserved = lock.withLock {
            guard pending[encodedID] == nil, pending.count < 16 else { return false }
            pending[encodedID] = true
            return true
        }
        guard reserved else {
            send(error(-32000, "Duplicate request ID or too many calls", id: id))
            return
        }
        group.enter()
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            defer { group.leave() }
            guard lock.withLock({ pending[encodedID] == true }) else {
                lock.withLock { _ = pending.removeValue(forKey: encodedID) }
                return
            }
            let body: RPCObject
            do {
                let data = try JSONSerialization.data(
                    withJSONObject: client.call(name, arguments: input),
                    options: [.sortedKeys, .withoutEscapingSlashes])
                body = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
            } catch {
                body = ["isError": true, "content": [["type": "text", "text": redact(error.localizedDescription)]]]
            }
            lock.withLock {
                if pending.removeValue(forKey: encodedID) == true {
                    try? AgentSocket.send(result(body, id: id), to: STDOUT_FILENO)
                }
            }
        }
    }

    private func requestID(_ id: Any) -> Data? {
        if let index = id as? NSNumber {
            guard CFGetTypeID(index) != CFBooleanGetTypeID(),
                index.doubleValue.isFinite, index.doubleValue.rounded() == index.doubleValue
            else { return nil }
        } else if !(id is String) {
            return nil
        }
        return try? JSONSerialization.data(withJSONObject: [id])
    }

    private func send(_ object: RPCObject) {
        lock.withLock { try? AgentSocket.send(object, to: STDOUT_FILENO) }
    }

    private func result(_ result: RPCObject, id: Any) -> RPCObject {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private func error(_ code: Int, _ message: String, id: Any, extra: RPCObject? = nil) -> RPCObject {
        var details: RPCObject = ["code": code, "message": message]
        details["data"] = extra
        return ["jsonrpc": "2.0", "id": id, "error": details]
    }

    private static func serverInfo() -> RPCObject {
        ["name": WorkbenchMCPConfiguration.name, "title": "UniCodex", "version": WorkbenchMCPConfiguration.version]
    }

    private static let tools: [RPCObject] = [
        tool(
            "dispatch_task", "Start a task. Reuse request_id for safe retries.",
            properties: [
                "prompt": ["type": "string", "minLength": 1],
                "workspace": [
                    "type": "string", "description": "Absolute folder path. Omit for the standalone workspace.",
                ],
                "provider": ["type": "string"], "model": ["type": "string"], "effort": ["type": "string"],
                "request_id": ["type": "string", "maxLength": 128],
            ], required: ["prompt"], readOnly: false, idempotent: false),
        tool(
            "task_status", "Check status or page the final answer. Use wait_seconds to reduce polling.",
            properties: [
                "task_id": ["type": "string"], "after_revision": ["type": "integer", "minimum": 1],
                "wait_seconds": ["type": "integer", "minimum": 0, "maximum": 20],
                "offset": ["type": "integer", "minimum": 0],
                "max_chars": ["type": "integer", "minimum": 0, "maximum": 6000],
            ], required: ["task_id"], readOnly: true, idempotent: true),
        tool(
            "cancel_task", "Stop a task dispatched through this MCP server.",
            properties: [
                "task_id": ["type": "string"]
            ], required: ["task_id"], readOnly: false, idempotent: true),
        tool(
            "list_models", "List configured model IDs. Filter by provider ID for reasoning levels.",
            properties: [
                "provider": ["type": "string"]
            ], required: [], readOnly: true, idempotent: true),
    ]

    private static func tool(
        _ name: String, _ description: String, properties: RPCObject,
        required: [String], readOnly: Bool, idempotent: Bool
    ) -> RPCObject {
        [
            "name": name, "description": description,
            "inputSchema": [
                "type": "object", "properties": properties, "required": required,
                "additionalProperties": false,
            ] as RPCObject,
            "annotations": [
                "readOnlyHint": readOnly, "destructiveHint": false,
                "idempotentHint": idempotent, "openWorldHint": name == "dispatch_task",
            ],
        ]
    }
}
