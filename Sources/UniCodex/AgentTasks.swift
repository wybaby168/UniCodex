import CryptoKit
import Foundation

enum AgentTaskStatus: String, Codable {
    case starting, running, stopping, completed, failed, cancelled, interrupted
    case waitingApproval = "waiting_approval"

    var isFinished: Bool {
        self == .completed || self == .failed || self == .cancelled || self == .interrupted
    }
}

struct AgentTaskRecord: Codable {
    let id: String
    let instance: UUID
    let fingerprint: String
    let provider: String
    let model: String
    var sessionID: String?
    var status: AgentTaskStatus = .starting
    var revision = 1
    var answer: String?
    var answerCapped: Bool?
    var error: String?

    func response(after: Int? = nil, offset: Int = 0, limit: Int = 0) -> RPCObject {
        if after == revision && offset == 0 {
            return ["task_id": id, "status": status.rawValue, "revision": revision, "unchanged": true]
        }
        var result: RPCObject = ["task_id": id, "status": status.rawValue, "revision": revision]
        result["session_id"] = sessionID
        result["error"] = error
        if status.isFinished, limit > 0, let answer, !answer.isEmpty {
            let count = answer.count
            let start = min(offset, count)
            let end = min(start + limit, count)
            result["answer"] = String(answer.dropFirst(start).prefix(end - start))
            if end < count { result["next_offset"] = end }
            if answerCapped == true { result["result_truncated"] = true }
        }
        return result
    }
}

@MainActor
final class AgentTaskStore {
    let instance = UUID()
    private let directory: URL
    private var live: [String: AgentTaskRecord] = [:]

    init(state: URL) {
        directory = state.appendingPathComponent("agent-tasks", isDirectory: true)
    }

    static func hash(_ text: Data, short: Bool = false) -> String {
        let bytes = SHA256.hash(data: text)
        return (short ? Array(bytes.prefix(16)) : Array(bytes)).map { String(format: "%02x", $0) }.joined()
    }

    static func id(for requestID: String?) -> String {
        let source = requestID.map { "request:" + $0 } ?? "task:" + UUID().uuidString
        return hash(Data(source.utf8), short: true)
    }

    func existing(_ id: String) throws -> AgentTaskRecord? {
        guard id.range(of: #"^[a-f0-9]{32}$"#, options: .regularExpression) != nil else {
            throw WorkbenchError("无效的任务 ID。")
        }
        if let record = live[id] { return record }
        let file = location(id)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true,
            (try? file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true
        else {
            throw WorkbenchError("无法读取工作台任务记录。")
        }
        var record = try JSONDecoder().decode(AgentTaskRecord.self, from: Data(contentsOf: file))
        guard record.id == id else { throw WorkbenchError("任务记录与 ID 不一致。") }
        if !record.status.isFinished && record.instance != instance {
            record.status = .interrupted
            record.revision += 1
            record.error = "工作台已重启。可在原会话查看此前进度。"
            try save(record)
        }
        return record
    }

    func create(_ record: AgentTaskRecord) throws {
        try save(record)
        live[record.id] = record
    }

    func update(_ id: String, status: AgentTaskStatus, sessionID: String?, answer: String?, error: String?) {
        guard var record = live[id], record.status != status || record.sessionID != sessionID else { return }
        record.status = status
        record.sessionID = sessionID
        record.revision += 1
        if status.isFinished {
            if let answer {
                record.answer = Self.prefix(answer, bytes: 64 * 1024)
                record.answerCapped = answer.utf8.count > 64 * 1024 ? true : nil
            }
            record.error = error.map { Self.prefix($0, bytes: 800) }
        }
        live[id] = record
        do {
            try save(record)
            if status.isFinished { live.removeValue(forKey: id) }
        } catch {
            // The receipt remains readable until exit if storage becomes unavailable mid-turn.
        }
    }

    func markInterrupted() {
        for item in Array(live.values) where !item.status.isFinished {
            update(
                item.id, status: .interrupted, sessionID: item.sessionID,
                answer: nil, error: "工作台已退出。可在原会话查看此前进度。")
        }
    }

    private static func prefix(_ value: String, bytes: Int) -> String {
        String(decoding: value.utf8.prefix(bytes), as: UTF8.self)
    }

    private func location(_ id: String) -> URL {
        directory.appendingPathComponent(id + ".json")
    }

    private func save(_ task: AgentTaskRecord) throws {
        let files = FileManager.default
        guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) != true else {
            throw WorkbenchError("工作台任务目录指向了其他位置。")
        }
        try files.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(task).write(to: location(task.id), options: .atomic)
    }
}

struct AgentDispatchArguments: Decodable {
    let prompt: String
    let workspace: String?
    let provider: String?
    let model: String?
    let effort: String?
    let requestID: String?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case prompt, workspace, provider, model, effort
        case requestID = "request_id"
    }
}

struct AgentStatusArguments: Decodable {
    let taskID: String
    let afterRevision: Int?
    let waitSeconds: Int?
    let offset: Int?
    let maxChars: Int?

    enum CodingKeys: String, CodingKey, CaseIterable {
        case taskID = "task_id"
        case afterRevision = "after_revision"
        case waitSeconds = "wait_seconds"
        case offset
        case maxChars = "max_chars"
    }
}
