import Foundation
import Network

/// A private loopback transport for the embedded Codex engine. Only this
/// object holds the Google key, and it sends native requests straight to Gemini.
final class GeminiTransport: @unchecked Sendable {
    let token = UUID().uuidString + UUID().uuidString

    private let key: String
    private let upstream: URL
    private let models: [String: ProviderModel]
    private let client = GeminiAPI.session(timeout: 90)
    private let listener: NWListener
    private let queue = DispatchQueue(label: "api-workbench.gemini-transport", qos: .userInitiated)
    private var connections: [ObjectIdentifier: NWConnection] = [:]

    private init(key: String, upstream: URL, models: [ProviderModel]) throws {
        self.key = key
        self.upstream = upstream
        self.models = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        let parameters = NWParameters.tcp
        parameters.requiredInterfaceType = .loopback
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
    }

    static func start(key: String, upstream: URL, models: [ProviderModel]) async throws -> (GeminiTransport, URL) {
        let transport = try GeminiTransport(key: key, upstream: upstream, models: models)
        do {
            let port = try await withTaskCancellationHandler {
                try await transport.listen()
            } onCancel: {
                transport.close()
            }
            try Task.checkCancellation()
            return (transport, URL(string: "http://127.0.0.1:\(port)")!)
        } catch {
            transport.close()
            throw error
        }
    }

    private func listen() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    self.listener.stateUpdateHandler = nil
                    if let port = self.listener.port {
                        continuation.resume(returning: port.rawValue)
                    } else {
                        continuation.resume(throwing: WorkbenchError("无法打开 Gemini 本机接口。"))
                    }
                case .waiting(let error), .failed(let error):
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                case .cancelled:
                    self.listener.stateUpdateHandler = nil
                    continuation.resume(throwing: CancellationError())
                default:
                    break
                }
            }
            listener.newConnectionHandler = { [weak self] connection in
                guard let self else {
                    connection.cancel()
                    return
                }
                self.accept(connection)
            }
            listener.start(queue: queue)
        }
    }

    func close() {
        listener.cancel()
        client.invalidateAndCancel()
        queue.async { [weak self] in
            guard let self else { return }
            for connection in connections.values {
                connection.cancel()
            }
        }
    }

    deinit {
        listener.cancel()
        client.invalidateAndCancel()
    }

    private func accept(_ connection: NWConnection) {
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        let task = Task.detached { [self] in
            await serve(connection)
            connection.cancel()
        }
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .cancelled, .failed:
                task.cancel()
                self?.connections.removeValue(forKey: id)
                connection.stateUpdateHandler = nil
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func serve(_ connection: NWConnection) async {
        do {
            let body = try await readRequest(connection)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, complete, error in
                if complete || error != nil { connection.cancel() }
            }
            guard let object = try JSONSerialization.jsonObject(with: body) as? RPCObject,
                let modelID = object["model"] as? String, let model = models[modelID]
            else {
                throw HTTPFailure(status: 400, message: "请选择此 Google 配置支持的 Gemini 模型。")
            }
            let request = try GeminiRequest(object, model: model)
            var url = URLComponents(
                url: upstream.appendingPathComponent("models")
                    .appendingPathComponent(model.id + ":streamGenerateContent"), resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "alt", value: "sse")]
            var google = GeminiAPI.request(at: url.url!, key: key)
            google.httpMethod = "POST"
            google.setValue("application/json", forHTTPHeaderField: "Content-Type")
            google.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            google.httpBody = try JSONSerialization.data(withJSONObject: request.payload)
            let (bytes, response) = try await client.bytes(for: google)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 502
            if status != 200 {
                let detail = try await errorDetail(from: bytes)
                throw HTTPFailure(
                    status: status,
                    message: [GeminiAPI.message(for: status), detail].filter { !$0.isEmpty }.joined(separator: " "))
            }
            try await send(
                Data(
                    "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\nCache-Control: no-cache\r\nConnection: close\r\n\r\n"
                        .utf8),
                to: connection)
            await relay(bytes, request: request, to: connection)
        } catch is CancellationError {
            return
        } catch let error as HTTPFailure {
            try? await sendError(error.message, status: error.status, to: connection)
        } catch let error as WorkbenchError {
            try? await sendError(error.localizedDescription, status: 400, to: connection)
        } catch {
            try? await sendError("无法连接 Google Gemini。\(error.localizedDescription)", status: 502, to: connection)
        }
    }

    private func relay(_ bytes: URLSession.AsyncBytes, request: GeminiRequest, to connection: NWConnection) async {
        var reply = GeminiResponse(request)
        do {
            try await send(reply.begin(), to: connection)
            var event = ""
            for try await line in bytes.lines where line.hasPrefix("data:") {
                if !event.isEmpty { event.append("\n") }
                event.append(contentsOf: line.dropFirst(5))
                guard event.utf8.count < 8 * 1024 * 1024 else { throw WorkbenchError("Gemini 返回的单条事件过大。") }
                if let chunk = try? JSONSerialization.jsonObject(with: Data(event.utf8)) as? RPCObject {
                    let update = try reply.consume(chunk)
                    if !update.isEmpty { try await send(update, to: connection) }
                    event.removeAll(keepingCapacity: true)
                }
            }
            guard event.isEmpty else { throw WorkbenchError("Gemini 返回了无法识别的流事件。") }
            try await send(reply.finish(), to: connection)
        } catch is CancellationError {
            return
        } catch {
            try? await send(reply.fail(safe(error.localizedDescription)), to: connection)
        }
    }

    private struct HTTPFailure: Error {
        let status: Int
        let message: String
    }

    private func readRequest(_ connection: NWConnection) async throws -> Data {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        while buffer.range(of: separator) == nil {
            buffer.append(try await receive(from: connection))
            if buffer.count > 128 * 1024 { throw HTTPFailure(status: 413, message: "请求头过大。") }
        }
        guard let end = buffer.range(of: separator),
            let header = String(data: buffer[..<end.lowerBound], encoding: .utf8)
        else {
            throw HTTPFailure(status: 400, message: "无效的 HTTP 请求。")
        }
        let lines = header.components(separatedBy: "\r\n")
        let target = lines.first?.split(separator: " ") ?? []
        guard target.count == 3, target[0] == "POST", target[1].split(separator: "?").first == "/responses" else {
            throw HTTPFailure(status: 404, message: "无效的 Gemini 本机请求地址。")
        }
        var fields: [String: String] = [:]
        for line in lines.dropFirst() {
            let field = line.split(separator: ":", maxSplits: 1)
            if field.count == 2 { fields[field[0].lowercased()] = field[1].trimmingCharacters(in: .whitespaces) }
        }
        guard fields["authorization"] == "Bearer " + token else {
            throw HTTPFailure(status: 401, message: "无法验证 Codex 引擎的本机连接。")
        }
        guard let length = Int(fields["content-length"] ?? ""), (1...48 * 1024 * 1024).contains(length) else {
            throw HTTPFailure(status: 413, message: "请求大小无效或超出 Gemini 接口限制。")
        }
        buffer.removeSubrange(..<end.upperBound)
        while buffer.count < length { buffer.append(try await receive(from: connection)) }
        return Data(buffer.prefix(length))
    }

    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, _, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let data, !data.isEmpty {
                    continuation.resume(returning: data)
                } else {
                    continuation.resume(throwing: CancellationError())
                }
            }
        }
    }

    private func send(_ data: Data, to connection: NWConnection) async throws {
        try Task.checkCancellation()
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error { continuation.resume(throwing: error) } else { continuation.resume() }
                })
        }
    }

    private func errorDetail(from bytes: URLSession.AsyncBytes) async throws -> String {
        var data = Data()
        for try await byte in bytes {
            if data.count >= 16 * 1024 { return "" }
            data.append(byte)
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? RPCObject,
            let error = object["error"] as? RPCObject, let detail = error["message"] as? String
        else { return "" }
        return String(safe(detail).prefix(600))
    }

    private func safe(_ message: String) -> String {
        redact(message.replacingOccurrences(of: key, with: "[API Key]").replacingOccurrences(of: token, with: "[本机凭据]"))
    }

    private func sendError(_ message: String, status: Int, to connection: NWConnection) async throws {
        let body = try JSONSerialization.data(withJSONObject: [
            "error": ["message": safe(message), "type": "gemini_error"]
        ])
        let http = (400...599).contains(status) ? status : 502
        var data = Data(
            "HTTP/1.1 \(http) Request Failed\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
                .utf8)
        data.append(body)
        try await send(data, to: connection)
    }
}
