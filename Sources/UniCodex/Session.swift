import Foundation
import Observation

struct ThreadSummary {
    let id: String
    let title: String
    let folder: URL
    let modelID: String?
    let providerID: String?
    let effort: String?

    init?(_ data: RPCObject) {
        guard let id = data["id"] as? String, let cwd = data["cwd"] as? String else { return nil }
        self.id = id
        folder = URL(fileURLWithPath: cwd, isDirectory: true)
        modelID = data["model"] as? String
        providerID = data["modelProvider"] as? String
        effort = data["reasoningEffort"] as? String
        let name = Self.cleanedName(data["name"] as? String ?? "")
        title = name.isEmpty ? Self.shortTitle(data["preview"] as? String ?? "") : name
    }

    static func cleanedName(_ input: String) -> String {
        input.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func shortTitle(_ input: String) -> String {
        let line =
            input.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        return line.isEmpty ? "新对话" : String(line.prefix(90))
    }
}

struct TranscriptEntry: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, Sendable { case user, answer, plan, progress, reasoning, activity }
    enum ActivityState: String, Codable, Sendable { case running, failed, complete }

    var id: String
    let kind: Kind
    var text: String
    var detail: String = ""
    var isStreaming = false
    var activityState: ActivityState? = nil
    var document: MessageDocument? = nil

    private enum CodingKeys: String, CodingKey {
        case id, kind, text, detail, isStreaming, activityState
    }

    var needsDocument: Bool {
        document == nil && !isStreaming && !text.isEmpty && kind != .activity && kind != .reasoning
    }

    var estimatedBytes: Int {
        let textBytes = text.utf8.count
        return 160 + textBytes + detail.utf8.count + (document == nil ? 0 : textBytes * 2)
    }

    func preparingDocument(in folder: URL) -> TranscriptEntry {
        guard needsDocument else { return self }
        var prepared = self
        prepared.document = MessageDocument(text, in: folder)
        return prepared
    }

    init(id: String, kind: Kind, text: String, detail: String = "", isStreaming: Bool = false) {
        self.id = id
        self.kind = kind
        self.text = text
        self.detail = detail
        self.isStreaming = isStreaming
    }

    init?(_ data: RPCObject) {
        guard let type = data["type"] as? String, let id = data["id"] as? String else { return nil }
        switch type {
        case "userMessage":
            let text = (data["content"] as? [RPCObject] ?? []).compactMap { $0["text"] as? String }
                .joined(separator: "\n")
            self.init(id: id, kind: .user, text: text)
        case "agentMessage":
            let kind: Kind = data["phase"] as? String == "commentary" ? .progress : .answer
            self.init(id: id, kind: kind, text: data["text"] as? String ?? "")
        case "reasoning":
            let summary = (data["summary"] as? [String] ?? []).filter { !$0.isEmpty }.joined(separator: "\n\n")
            guard !summary.isEmpty else { return nil }
            self.init(id: id, kind: .reasoning, text: summary)
        case "commandExecution":
            let parts = [data["command"] as? String, data["aggregatedOutput"] as? String].compactMap { $0 }
            let exit = data["exitCode"] as? Int
            let status = data["status"] as? String
            let title: String
            if status == "declined" {
                title = "命令已拒绝"
            } else if let exit, exit != 0 {
                title = "命令退出（\(exit)）"
            } else if status == "failed" {
                title = "命令失败"
            } else if exit == 0 || status == "completed" {
                title = "命令已完成"
            } else {
                title = "运行命令"
            }
            self.init(id: id, kind: .activity, text: title, detail: Self.boundedLog(parts.joined(separator: "\n\n")))
            activityState = Self.activityStatus(status, exit: exit)
        case "fileChange":
            let changes = data["changes"] as? [RPCObject] ?? []
            let body = changes.map {
                [$0["path"] as? String, $0["diff"] as? String].compactMap { $0 }.joined(separator: "\n")
            }
            let title = data["status"] as? String == "failed" ? "文件修改失败" : "文件修改"
            self.init(id: id, kind: .activity, text: title, detail: Self.boundedLog(body.joined(separator: "\n\n")))
            activityState = Self.activityStatus(data["status"] as? String)
        case "mcpToolCall", "dynamicToolCall":
            self.init(id: id, kind: .activity, text: "工具 · " + (data["tool"] as? String ?? "Codex"))
            activityState = Self.activityStatus(data["status"] as? String)
        case "plan":
            self.init(id: id, kind: .plan, text: data["text"] as? String ?? "")
        default:
            return nil
        }
    }

    private static func activityStatus(_ status: String?, exit: Int? = nil) -> ActivityState {
        if status == "inProgress" { return .running }
        if status == "failed" || status == "declined" || exit.map({ $0 != 0 }) == true { return .failed }
        return .complete
    }

    static func boundedLog(_ text: String) -> String {
        if text.utf8.count <= 20_000 { return redact(text) }
        return redact(String(text.prefix(3_000)) + "\n\n… 已省略部分输出 …\n\n" + String(text.suffix(7_000)))
    }
}

@Observable @MainActor
final class WorkbenchSession: Identifiable {
    static let recentEntryLimit = 96
    static let recentEstimatedByteLimit = 4 * 1_024 * 1_024

    enum LoadState { case ready, unloaded, loading, failed }
    enum RunState: Equatable {
        case idle
        case starting
        case running(String)
        case stopping(String)

        var turnID: String? {
            switch self {
            case .running(let id), .stopping(let id): id
            default: nil
            }
        }
    }

    let id = UUID()
    var threadID: String?
    var title: String
    var folder: URL
    var modelID: String
    var profileID = ProviderProfile.originalID
    var runningRoute: ModelRoute?
    var collaborationModeID = CollaborationMode.standard.id
    var runningCollaborationModeID: String?
    var contextLimited = false
    var reasoningByModel: [String: String]
    var permissionMode: SessionPermissionMode = .workspace
    var draft = ""
    var isArchived = false
    var isManaging = false
    var loadState: LoadState = .ready
    var runState: RunState = .idle
    enum FinalStatus: String {
        case completed = "session.finished"
        case stopped = "session.cancelled"
        case disconnected = "session.interrupted"
        case failed = "session.failed"
    }
    var finalStatus: FinalStatus?
    var error: String?
    var hasUnreadResult = false
    var approvals: [Approval] = []
    var answeringApprovalIDs: Set<String> = []
    var inputRequests: [UserInputRequest] = []
    var answeringInputIDs: Set<String> = []
    var expandedOperations: Set<String> = []
    private(set) var entries: [TranscriptEntry] = []
    private(set) var revision = 0

    @ObservationIgnored var submissionID: String?
    @ObservationIgnored var runningConnection: CodexConnection?
    @ObservationIgnored var runningThreadID: String?
    @ObservationIgnored var optimisticID: String?
    @ObservationIgnored var lastFinishedTurnID: String?
    @ObservationIgnored var pendingDraftName: String?
    @ObservationIgnored var agentTaskID: String?
    @ObservationIgnored var agentTurnAcknowledged = false
    @ObservationIgnored private var timeline = TranscriptIndex()
    @ObservationIgnored private var changedFrom: Int?
    @ObservationIgnored private var positions: [String: Int] = [:]
    private struct StreamKey: Hashable {
        let id: String
        let summaryIndex: Int?
        let kind: TranscriptEntry.Kind
    }
    @ObservationIgnored private var deltaOrder: [StreamKey] = []
    @ObservationIgnored private var deltas: [StreamKey: String] = [:]
    @ObservationIgnored private var summaryParts: [String: [Int: String]] = [:]
    @ObservationIgnored private var deltaFlush: Task<Void, Never>?
    @ObservationIgnored private var streamingIDs: Set<String> = []
    @ObservationIgnored private var pendingDocuments = Set<String>()
    @ObservationIgnored private var documentWorker: Task<Void, Never>?

    init(folder: URL, modelID: String, reasoningByModel: [String: String], title: String = "新对话") {
        self.folder = folder
        self.modelID = modelID
        self.reasoningByModel = reasoningByModel
        self.title = title
    }

    var route: ModelRoute { .init(profileID: profileID, modelID: modelID) }

    func key(for id: String, in engineThread: String) -> String {
        threadID == engineThread ? id : engineThread + "/" + id
    }

    var isActive: Bool { runState != .idle }
    var isLoading: Bool { loadState == .loading }
    var awaitsInteraction: Bool { !approvals.isEmpty || !inputRequests.isEmpty }
    var proposedPlan: TranscriptEntry? {
        entries.reversed().prefix { $0.kind != .user }
            .first { $0.kind == .plan && !$0.isStreaming && !$0.text.isEmpty }
    }
    var hasVisibleEntries: Bool {
        _ = revision
        return !timeline.records.isEmpty
    }
    var isEmptyDraft: Bool {
        threadID == nil && entries.isEmpty && draft.isEmpty && pendingDraftName == nil && !isActive
    }
    func displayTitle(using strings: UIStrings) -> String {
        if threadID == nil, pendingDraftName == nil, title == "新对话" { return strings.text("common.new_chat") }
        return title
    }

    func status(using strings: UIStrings) -> String {
        if !inputRequests.isEmpty && isActive { return strings.text("question.waiting") }
        if !approvals.isEmpty && isActive { return strings.text("session.waiting") }
        switch runState {
        case .starting: return strings.text("session.sending")
        case .running: return strings.text("session.running")
        case .stopping: return strings.text("session.stopping")
        case .idle: return isLoading ? strings.text("session.opening") : strings.text(finalStatus?.rawValue ?? "")
        }
    }

    func entry(_ id: String) -> TranscriptEntry? {
        positions[id].map { entries[$0] }
    }

    func transcriptSnapshot() -> TranscriptSnapshot { timeline.snapshot(recent: entries, folder: folder) }

    func takeChangedTranscriptRange() -> Int? {
        defer { changedFrom = nil }
        return changedFrom
    }

    func transcriptPosition(of id: String) -> Int? { timeline.positions[id] }

    func upsert(_ item: TranscriptEntry) {
        flushDeltas()
        insert(item)
        if !item.isStreaming { summaryParts.removeValue(forKey: item.id) }
        trimRecentEntries()
    }

    func appendDelta(id: String, text: String, summaryIndex: Int? = nil, kind: TranscriptEntry.Kind = .answer) {
        guard !text.isEmpty else { return }
        let key = StreamKey(id: id, summaryIndex: summaryIndex, kind: kind)
        if deltas[key] == nil { deltaOrder.append(key) }
        deltas[key, default: ""] += text
        guard deltaFlush == nil else { return }
        deltaFlush = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: .milliseconds(34)) } catch { return }
            self?.flushDeltas()
        }
    }

    func flushDeltas() {
        deltaFlush?.cancel()
        deltaFlush = nil
        guard !deltaOrder.isEmpty else { return }
        for key in deltaOrder {
            guard let text = deltas[key] else { continue }
            let id = key.id
            if let part = key.summaryIndex {
                var summary = summaryParts[id] ?? [:]
                summary[part, default: ""] += text
                summaryParts[id] = summary
                let rendered = summary.keys.sorted().compactMap { summary[$0] }.joined(separator: "\n\n")
                insert(.init(id: id, kind: .reasoning, text: rendered, isStreaming: true))
            } else {
                if let index = positions[id] {
                    entries[index].text += text
                    entries[index].isStreaming = true
                    entries[index].document = nil
                } else {
                    positions[id] = entries.count
                    entries.append(.init(id: id, kind: key.kind, text: text, isStreaming: true))
                }
                if let index = positions[id] { markChanged(timeline.update(entries[index])) }
                streamingIDs.insert(id)
            }
        }
        deltaOrder.removeAll(keepingCapacity: true)
        deltas.removeAll(keepingCapacity: true)
        revision += 1
        trimRecentEntries()
    }

    func settleOutput() {
        flushDeltas()
        summaryParts.removeAll(keepingCapacity: true)
        if !streamingIDs.isEmpty {
            for id in streamingIDs {
                if let index = positions[id] {
                    entries[index].isStreaming = false
                    markChanged(timeline.update(entries[index]))
                    prepareDocument(for: entries[index])
                }
            }
            streamingIDs.removeAll()
            revision += 1
        }
        trimRecentEntries()
    }

    func clearRequests() {
        approvals.removeAll()
        answeringApprovalIDs.removeAll()
        inputRequests.removeAll()
        answeringInputIDs.removeAll()
    }

    func clearRequest(_ id: String) {
        approvals.removeAll { $0.id == id }
        answeringApprovalIDs.remove(id)
        inputRequests.removeAll { $0.id == id }
        answeringInputIDs.remove(id)
    }

    func loadTranscript(_ archive: TranscriptArchive) {
        flushDeltas()
        let live = isActive ? entries : []
        timeline = archive.index
        let liveIDs = Set(live.map(\.id))
        entries = archive.recent.filter { !liveIDs.contains($0.id) } + live
        for entry in live { _ = timeline.update(entry) }
        markChanged(0)
        rebuildIndex()
        trimRecentEntries()
    }

    func releaseTranscript() {
        guard !isActive && threadID != nil else { return }
        deltaFlush?.cancel()
        deltaFlush = nil
        deltaOrder.removeAll()
        deltas.removeAll()
        summaryParts.removeAll()
        streamingIDs.removeAll()
        pendingDocuments.removeAll()
        entries = []
        positions.removeAll()
        timeline = TranscriptIndex()
        expandedOperations.removeAll()
        markChanged(0)
        loadState = .unloaded
        revision += 1
    }

    func reconcileUser(_ item: TranscriptEntry, clientID: String?) -> Bool {
        guard let provisional = optimisticID, let index = positions[provisional],
            clientID == provisional || entries[index].text == item.text
        else {
            return false
        }
        if let duplicate = positions[item.id], duplicate != index {
            entries.remove(at: index)
            rebuildIndex()
        } else {
            positions.removeValue(forKey: provisional)
            positions[item.id] = index
            entries[index] = item
        }
        if let changed = timeline.reconcile(provisional, with: item) { markChanged(changed) }
        revision += 1
        optimisticID = nil
        return true
    }

    func removeUnacknowledgedInput() {
        guard let id = optimisticID, let index = positions[id] else { return }
        if draft.isEmpty { draft = entries[index].text }
        entries.remove(at: index)
        if let changed = timeline.remove(id) { markChanged(changed) }
        optimisticID = nil
        rebuildIndex()
    }

    private func insert(_ input: TranscriptEntry) {
        guard !input.text.isEmpty else { return }
        var item = input
        if let index = positions[item.id] {
            if item.needsDocument && entries[index].text == item.text {
                item.document = entries[index].document
            }
            entries[index] = item
        } else {
            positions[item.id] = entries.count
            entries.append(item)
        }
        if item.isStreaming { streamingIDs.insert(item.id) } else { streamingIDs.remove(item.id) }
        markChanged(timeline.update(item))
        revision += 1
        prepareDocument(for: item)
    }

    private func prepareDocument(for item: TranscriptEntry) {
        guard item.needsDocument else { return }
        pendingDocuments.insert(item.id)
        guard documentWorker == nil else { return }
        documentWorker = Task { [weak self] in
            await self?.preparePendingDocuments()
        }
    }

    private func preparePendingDocuments() async {
        defer { documentWorker = nil }
        while let item = entries.last(where: { pendingDocuments.contains($0.id) }) {
            pendingDocuments.remove(item.id)
            guard item.needsDocument else { continue }
            let folder = self.folder
            let document = await Task.detached(priority: .userInitiated) {
                MessageDocument(item.text, in: folder)
            }.value
            if self.folder == folder { applyDocument(document, for: item) }
        }
        pendingDocuments.removeAll()
    }

    private func applyDocument(_ document: MessageDocument, for item: TranscriptEntry) {
        guard let index = positions[item.id], entries[index].needsDocument,
            entries[index].kind == item.kind, entries[index].text == item.text
        else { return }
        entries[index].document = document
        revision += 1
        trimRecentEntries()
    }

    private func trimRecentEntries() {
        guard threadID != nil, entries.count > 1 else { return }
        var bytes = entries.reduce(0) { $0 + $1.estimatedBytes }
        var count = entries.count
        guard count > Self.recentEntryLimit || bytes > Self.recentEstimatedByteLimit else { return }
        var evicted = Set<String>()
        for entry in entries.dropLast() {
            guard count > Self.recentEntryLimit || bytes > Self.recentEstimatedByteLimit else { break }
            guard !streamingIDs.contains(entry.id), entry.id != optimisticID,
                entry.activityState != .running
            else { continue }
            do { try timeline.store(entry) } catch { break }
            evicted.insert(entry.id)
            count -= 1
            bytes -= entry.estimatedBytes
        }
        guard !evicted.isEmpty else { return }
        entries.removeAll { evicted.contains($0.id) }
        pendingDocuments.subtract(evicted)
        rebuildIndex()
    }

    private func markChanged(_ index: Int) {
        changedFrom = min(changedFrom ?? index, index)
    }

    private func rebuildIndex() {
        positions = Dictionary(uniqueKeysWithValues: entries.enumerated().map { ($0.element.id, $0.offset) })
        revision += 1
    }
}
