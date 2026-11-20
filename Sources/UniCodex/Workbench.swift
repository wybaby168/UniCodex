import Foundation
import Observation

struct ReasoningChoice: Identifiable {
    let id: String
    var name: String {
        switch id {
        case "none": UIStrings.current.text("reasoning.none")
        case "minimal": UIStrings.current.text("reasoning.minimal")
        case "low": UIStrings.current.text("reasoning.low")
        case "medium": UIStrings.current.text("reasoning.medium")
        case "high": UIStrings.current.text("reasoning.high")
        case "xhigh": UIStrings.current.text("reasoning.xhigh")
        case "max": UIStrings.current.text("reasoning.max")
        case "ultra": UIStrings.current.text("reasoning.ultra")
        default: id
        }
    }

    var menuTitle: String { name == id ? id : "\(name) · \(id)" }
}

struct ModelChoice: Identifiable {
    let id: String
    let name: String
    let defaultEffort: String?
    let reasoningChoices: [ReasoningChoice]
    let isDefault: Bool

    init(id: String, name: String, defaultEffort: String?, efforts: [String], isDefault: Bool = false) {
        self.id = id
        self.name = name
        self.defaultEffort = defaultEffort
        var seen = Set<String>()
        let available = efforts.filter { !$0.isEmpty && seen.insert($0).inserted }
        reasoningChoices = available.map(ReasoningChoice.init(id:))
        self.isDefault = isDefault
    }

    init?(_ data: RPCObject) {
        guard data["hidden"] as? Bool != true,
            let id = data["model"] as? String, !id.isEmpty
        else { return nil }
        if let modalities = data["inputModalities"] as? [String], !modalities.contains("text") {
            return nil
        }
        let efforts = (data["supportedReasoningEfforts"] as? [RPCObject] ?? [])
            .compactMap { $0["reasoningEffort"] as? String }
        self.init(
            id: id, name: data["displayName"] as? String ?? id,
            defaultEffort: data["defaultReasoningEffort"] as? String, efforts: efforts,
            isDefault: data["isDefault"] as? Bool ?? false)
    }

    func reasoning(preferred: String?) -> ReasoningChoice? {
        reasoningChoices.first { $0.id == preferred } ?? reasoningChoices.first { $0.id == defaultEffort }
            ?? reasoningChoices.first
    }

}

@Observable @MainActor
final class Workbench {
    enum Connection: Equatable { case connecting, ready, unavailable }
    private(set) var connection: Connection = .connecting
    private(set) var connectionStatus = ""
    private(set) var connectionError: String?
    private(set) var sessions: [WorkbenchSession]
    private(set) var selected: WorkbenchSession
    private(set) var moreConversations = false
    private(set) var archivedSessions: [WorkbenchSession] = []
    private(set) var loadingArchives = false
    private(set) var moreArchives = false
    private(set) var archiveError: String?
    private(set) var models: [ModelChoice] = []
    private(set) var openAICatalog: [ModelChoice] = []
    let providers: ProviderConfiguration
    private(set) var permissionModes = SessionPermissionMode.allCases
    private(set) var collaborationModes: [CollaborationMode] = []

    private let paths: EnginePaths
    private let defaults: UserDefaults
    @ObservationIgnored private var rpc: CodexConnection?
    @ObservationIgnored private let enginePool: ProviderEnginePool
    @ObservationIgnored private var threadOwners: [String: CodexConnection] = [:]
    @ObservationIgnored private var byThread: [String: WorkbenchSession] = [:]
    @ObservationIgnored private var threadCursor: String?
    @ObservationIgnored private var archiveCursor: String?
    @ObservationIgnored private var deletedThreadIDs: Set<String> = []
    @ObservationIgnored private var listing = false
    @ObservationIgnored private var connecting = false
    @ObservationIgnored private var defaultModelID: String
    @ObservationIgnored private var effortPreferences: [String: String]
    @ObservationIgnored private var permissionPreferences: [String: String]
    @ObservationIgnored private var collaborationPreferences: [String: String]
    @ObservationIgnored private var firstSelection: UUID?
    @ObservationIgnored private lazy var agentTasks = AgentTaskStore(state: paths.state)
    @ObservationIgnored private var agentStopRequests = Set<String>()
    var agentServiceError: String?

    private static let modelPreference = "selectedAPIModel"
    private static let reasoningPreference = "selectedReasoningByModel"
    private static let threadPreference = "lastWorkbenchThread"
    private static let permissionPreference = "workbenchThreadPermissions"
    private static let collaborationPreference = "workbenchCollaborationModes"

    init(
        paths: EnginePaths = .local, defaults: UserDefaults = .standard,
        profileKeys: ProfileKeyStore = KeychainProfileKeys()
    ) {
        self.paths = paths
        self.defaults = defaults
        let providers = ProviderConfiguration(defaults: defaults, keys: profileKeys)
        self.providers = providers
        enginePool = ProviderEnginePool(paths: paths, configuration: providers)
        let model = defaults.string(forKey: Self.modelPreference) ?? EnginePaths.defaultModelID
        let efforts = defaults.dictionary(forKey: Self.reasoningPreference) as? [String: String] ?? [:]
        defaultModelID = model
        effortPreferences = efforts
        permissionPreferences = defaults.dictionary(forKey: Self.permissionPreference) as? [String: String] ?? [:]
        collaborationPreferences = defaults.dictionary(forKey: Self.collaborationPreference) as? [String: String] ?? [:]
        let saved = defaults.string(forKey: "workspacePath").map { URL(fileURLWithPath: $0, isDirectory: true) }
        let folder = saved ?? paths.workspace
        let profile = providers.profile(providers.defaultProfileID) ?? .original
        let session = WorkbenchSession(
            folder: folder, modelID: profile.isOriginal ? model : profile.defaultModel,
            reasoningByModel: efforts)
        session.profileID = profile.id
        selected = session
        sessions = [session]
        firstSelection = session.id
    }

    var numberRunning: Int { sessions.count(where: \.isActive) }
    var hasRunningWork: Bool { sessions.contains(where: \.isActive) }

    func folderName(for session: WorkbenchSession) -> String {
        session.folder.standardizedFileURL == paths.workspace.standardizedFileURL
            ? UIStrings.current.text("session.workspace") : session.folder.lastPathComponent
    }
    func profile(for session: WorkbenchSession) -> ProviderProfile {
        providers.profile(session.profileID) ?? .original
    }
    func models(for profile: ProviderProfile) -> [ModelChoice] {
        if profile.isOriginal { return models }
        return profile.kind == .openAI ? (openAICatalog.isEmpty ? models : openAICatalog) : profile.catalog
    }
    func model(for session: WorkbenchSession) -> ModelChoice? {
        models(for: profile(for: session)).first { $0.id == session.modelID }
    }
    func reasoningChoices(for session: WorkbenchSession) -> [ReasoningChoice] {
        model(for: session)?.reasoningChoices ?? []
    }
    private func reasoningKey(_ route: ModelRoute) -> String {
        route.profileID == ProviderProfile.originalID ? route.modelID : route.profileID + "/" + route.modelID
    }
    func reasoning(for session: WorkbenchSession) -> ReasoningChoice? {
        model(for: session)?.reasoning(preferred: session.reasoningByModel[reasoningKey(session.route)])
    }
    func canSend(in session: WorkbenchSession) -> Bool {
        canStartTurn(in: session) && !session.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
    private func canStartTurn(in session: WorkbenchSession) -> Bool {
        connection == .ready && session.loadState == .ready && !session.isActive && !session.isManaging
            && !session.isArchived && providers.configured(profile(for: session)) && model(for: session) != nil
            && permissionModes.contains(session.permissionMode)
    }
    func collaborationMode(for session: WorkbenchSession) -> CollaborationMode {
        collaborationModes.first { $0.id == session.collaborationModeID } ?? .standard
    }
    func selectCollaborationMode(_ id: String, in session: WorkbenchSession) {
        guard !session.isArchived, !session.isManaging, collaborationModes.contains(where: { $0.id == id }) else {
            return
        }
        session.collaborationModeID = id
        recordCollaborationMode(for: session)
    }
    func canImplementPlan(in session: WorkbenchSession) -> Bool {
        canStartTurn(in: session) && collaborationMode(for: session).isPlan
            && collaborationModes.contains { $0.id == CollaborationMode.standard.id }
            && (session.finalStatus == nil || session.finalStatus == .completed)
            && session.proposedPlan != nil
    }
    func implementPlan(in session: WorkbenchSession) {
        guard canImplementPlan(in: session), session.draft.isEmpty else { return }
        selectCollaborationMode(CollaborationMode.standard.id, in: session)
        session.draft = UIStrings.current.text("mode.implement_prompt")
        send(in: session)
    }
    func canStop(in session: WorkbenchSession) -> Bool {
        guard session.runningConnection?.isOpen == true, case .running = session.runState else { return false }
        return true
    }
    func selectModel(_ id: String, in session: WorkbenchSession) {
        selectRoute(.init(profileID: session.profileID, modelID: id), in: session)
    }
    func selectRoute(_ route: ModelRoute, in session: WorkbenchSession) {
        guard !session.isArchived, let profile = providers.profile(route.profileID), providers.configured(profile),
            models(for: profile).contains(where: { $0.id == route.modelID })
        else { return }
        if let threadID = session.threadID {
            do { try providers.record(.init(segments: segments(for: session), selection: route), for: threadID) } catch
            {
                session.error = error.localizedDescription
                return
            }
        }
        session.profileID = route.profileID
        session.modelID = route.modelID
        if profile.isOriginal {
            defaultModelID = route.modelID
            defaults.set(route.modelID, forKey: Self.modelPreference)
        }
    }
    func selectReasoning(_ id: String, in session: WorkbenchSession) {
        guard reasoningChoices(for: session).contains(where: { $0.id == id }) else { return }
        let key = reasoningKey(session.route)
        session.reasoningByModel[key] = id
        effortPreferences[key] = id
        defaults.set(effortPreferences, forKey: Self.reasoningPreference)
    }

    func useProfile(_ id: String, in session: WorkbenchSession) {
        guard let profile = providers.profile(id) else { return }
        selectRoute(preferredRoute(for: profile), in: session)
    }
    func providerConfigurationChanged() {
        guard !sessions.contains(where: { $0.isLoading || $0.isManaging }) else { return }
        enginePool.reapChangedProfiles(retaining: sessions.compactMap(\.runningConnection))
        threadOwners = threadOwners.filter { $0.value.isOpen }
    }
    func routeWillContinueHistory(in session: WorkbenchSession) -> Bool {
        guard let last = segments(for: session).last else { return false }
        return !canReuse(last, for: session.route, profile: profile(for: session))
    }

    func selectPermissionMode(_ mode: SessionPermissionMode, in session: WorkbenchSession) {
        guard connection == .ready, !session.isActive, permissionModes.contains(mode) else { return }
        session.permissionMode = mode
        recordPermissionMode(for: session)
    }

    @discardableResult
    func newConversation(in folder: URL? = nil) -> WorkbenchSession {
        firstSelection = nil
        let location = (folder ?? selected.folder).standardizedFileURL
        let profile = providers.profile(providers.defaultProfileID) ?? .original
        let route = preferredRoute(for: profile)
        let session = WorkbenchSession(folder: location, modelID: route.modelID, reasoningByModel: effortPreferences)
        session.profileID = route.profileID
        // Retire a blank placeholder; retain editable drafts and submitted threads.
        if selected.isEmptyDraft {
            sessions.removeAll { $0 === selected }
        }
        sessions.insert(session, at: 0)
        focus(session)
        return session
    }

    func changeFolder(_ location: URL, in session: WorkbenchSession) {
        let folder = location.resolvingSymlinksInPath()
        if session.threadID == nil && !session.isActive && session.entries.isEmpty {
            session.folder = folder
            recordFolder(folder)
        } else {
            newConversation(in: folder)
        }
    }

    func focus(_ session: WorkbenchSession) {
        guard !session.isArchived else { return }
        selected = session
        session.hasUnreadResult = false
        recordFolder(session.folder)
        if let threadID = session.threadID { defaults.set(threadID, forKey: Self.threadPreference) }
        if session.loadState == .unloaded { openHistory(in: session) }
        releaseUnusedTranscripts()
    }

    func connect() {
        guard rpc == nil, !connecting else { return }
        connecting = true
        connection = .connecting
        connectionError = nil
        connectionStatus = "connection.start"
        Task {
            defer { connecting = false }
            do {
                try paths.prepare()
                let server = try CodexConnection(paths: paths)
                rpc = server
                handleNotifications(from: server)
                try await ProviderEnginePool.initialize(server, paths: paths)
                var originalKey: String?
                if let key = try? paths.credential(),
                    let login = try? await server.request("account/login/start", ["type": "apiKey", "apiKey": key]),
                    login["type"] as? String == "apiKey",
                    let account = try? await server.request("account/read", ["refreshToken": false]),
                    (account["account"] as? RPCObject)?["type"] as? String == "apiKey"
                {
                    originalKey = key
                }
                providers.noteOriginalKey(available: originalKey != nil)
                connectionStatus = "connection.catalog"
                async let requirements = try? server.request("configRequirements/read", timeout: 5)
                async let modes = try? server.request("collaborationMode/list", timeout: 5)
                await loadModels(server, key: originalKey)
                let configuredRequirements = (await requirements)?["requirements"] as? RPCObject ?? [:]
                let supportedModes = CollaborationMode.advertised(in: await modes)
                guard rpc === server else { return }
                permissionModes = SessionPermissionMode.allCases.filter { $0.allowed(by: configuredRequirements) }
                collaborationModes = supportedModes
                connectionStatus = ""
                connection = .ready
                await loadConversations()
                guard rpc === server else { return }
                if let firstSelection, selected.id == firstSelection, selected.isEmptyDraft,
                    let last = defaults.string(forKey: Self.threadPreference), let saved = byThread[last],
                    !saved.isArchived
                {
                    let placeholder = selected
                    focus(saved)
                    sessions.removeAll { $0 === placeholder }
                } else if selected.loadState == .unloaded {
                    openHistory(in: selected)
                }
                firstSelection = nil
            } catch {
                if let rpc {
                    didDisconnect(rpc, message: error.localizedDescription)
                    rpc.stop()
                } else {
                    markManagerUnavailable(error.localizedDescription)
                }
            }
        }
    }

    func close() {
        agentTasks.markInterrupted()
        let server = rpc
        rpc = nil
        server?.stop()
        enginePool.stopAll()
        threadOwners.removeAll()
    }

    func dismissConnectionError() { connectionError = nil }

    func openHistory(in session: WorkbenchSession) {
        guard !session.isArchived, !session.isManaging, !session.isLoading, session.loadState != .ready,
            let manager = rpc, let root = session.threadID, connection == .ready
        else { return }
        session.loadState = .loading
        session.error = nil
        let previous = segments(for: session)
        Task {
            do {
                var archive = TranscriptArchiveBuilder()
                for segment in previous {
                    try await TranscriptHistoryReader.read(
                        manager, threadID: segment.threadID,
                        namespace: root == segment.threadID ? nil : segment.threadID, into: &archive)
                }
                let history = await archive.finish(in: session.folder)
                guard self.rpc === manager else { return }
                session.loadTranscript(history)
                session.loadState = .ready
                providerConfigurationChanged()
                releaseUnusedTranscripts()
            } catch {
                guard self.rpc === manager else { return }
                session.loadState = .failed
                providerConfigurationChanged()
                session.error = redact(error.localizedDescription)
            }
        }
    }

    private func releaseUnusedTranscripts() {
        // Keep one other idle transcript warm. Active turns and draft text are retained.
        let inactive = sessions.filter {
            $0 !== selected && $0.threadID != nil && !$0.isActive && !$0.isManaging && $0.loadState == .ready
        }
        for session in inactive.dropFirst() { session.releaseTranscript() }
    }

    func loadMoreConversations() { Task { await loadConversations(append: true) } }

    func loadArchivedConversations(append: Bool = false) async {
        guard connection == .ready else {
            archiveError = UIStrings.current.text("error.archive_offline")
            return
        }
        await loadConversations(append: append, archived: true)
    }

    func canRename(_ session: WorkbenchSession) -> Bool {
        canManage(session) && !session.isArchived && session.runState != .starting
            && (session.threadID != nil || !session.isActive)
    }

    func canMoveOrDelete(_ session: WorkbenchSession) -> Bool {
        canManage(session) && !session.isActive && !session.isLoading
    }

    private func canManage(_ session: WorkbenchSession) -> Bool {
        !session.isManaging && (session.threadID == nil || connection == .ready)
    }

    func rename(_ session: WorkbenchSession, to input: String) async throws {
        let name = ThreadSummary.cleanedName(input)
        guard !name.isEmpty else { throw WorkbenchError(UIStrings.current.text("error.name_required")) }
        guard canRename(session), contains(session) else {
            throw WorkbenchError(UIStrings.current.text("error.rename"))
        }
        guard name != session.title || (session.threadID != nil && session.pendingDraftName != nil) else { return }
        if session.threadID == nil {
            session.title = name
            session.pendingDraftName = name
            return
        }
        try await mutateThread(session, method: "thread/name/set", fields: ["name": name]) {
            session.title = name
            session.pendingDraftName = nil
        }
    }

    func setArchived(_ session: WorkbenchSession, _ archived: Bool) async throws {
        guard session.isArchived != archived else { return }
        guard canMoveOrDelete(session), session.threadID != nil, contains(session) else {
            throw WorkbenchError(UIStrings.current.text("error.chat_busy"))
        }
        let segments = segments(for: session)
        session.isManaging = true
        defer { session.isManaging = false }
        let method = archived ? "thread/archive" : "thread/unarchive"
        let undo = archived ? "thread/unarchive" : "thread/archive"
        var changed: [(String, CodexConnection)] = []
        do {
            // The primary segment is the sidebar's authoritative archive record.
            for segment in segments.reversed() {
                let engine = try await managementRuntime(for: segment)
                _ = try await engine.request(method, ["threadId": segment.threadID])
                changed.append((segment.threadID, engine))
            }
            applyArchiveState(session, archived: archived)
        } catch {
            for (id, engine) in changed.reversed() {
                _ = try? await engine.request(undo, ["threadId": id], timeout: 5)
            }
            throw error
        }
    }

    func delete(_ session: WorkbenchSession) async throws {
        guard canMoveOrDelete(session), contains(session) else {
            throw WorkbenchError(UIStrings.current.text("error.chat_busy"))
        }
        guard let root = session.threadID else {
            removeFromSidebar(session)
            return
        }
        session.isManaging = true
        defer { session.isManaging = false }
        var remaining = segments(for: session)
        for segment in remaining where segment.threadID != root {
            let engine = try await managementRuntime(for: segment)
            _ = try await engine.request("thread/delete", ["threadId": segment.threadID])
            remaining.removeAll { $0.threadID == segment.threadID }
            try providers.record(.init(segments: remaining, selection: session.route), for: root)
            byThread.removeValue(forKey: segment.threadID)
            threadOwners.removeValue(forKey: segment.threadID)
        }
        guard let primary = remaining.first else { throw WorkbenchError(UIStrings.current.text("error.chat_missing")) }
        let engine = try await managementRuntime(for: primary)
        _ = try await engine.request("thread/delete", ["threadId": root])
        applyDeletion(root)
    }

    private func contains(_ session: WorkbenchSession) -> Bool {
        (session.isArchived ? archivedSessions : sessions).contains { $0 === session }
    }

    private func mutateThread(
        _ session: WorkbenchSession, method: String, fields: RPCObject = [:],
        commit: () -> Void
    ) async throws {
        guard let primary = segments(for: session).first, connection == .ready else {
            throw WorkbenchError(UIStrings.current.text("error.engine_offline"))
        }
        session.isManaging = true
        defer {
            session.isManaging = false
            if selected === session && session.loadState == .unloaded { openHistory(in: session) }
        }
        var params = fields
        params["threadId"] = primary.threadID
        let engine = try await managementRuntime(for: primary)
        _ = try await engine.request(method, params)
        commit()
    }

    private func applyArchiveState(_ session: WorkbenchSession, archived: Bool) {
        guard session.isArchived != archived else { return }
        session.isArchived = archived
        session.loadState = .unloaded
        if archived {
            session.releaseTranscript()
            archivedSessions.insert(session, at: 0)
            removeFromSidebar(session)
        } else {
            archivedSessions.removeAll { $0 === session }
            sessions.insert(session, at: 0)
        }
    }

    private func applyDeletion(_ threadID: String) {
        deletedThreadIDs.insert(threadID)
        if permissionPreferences.removeValue(forKey: threadID) != nil {
            defaults.set(permissionPreferences, forKey: Self.permissionPreference)
        }
        if collaborationPreferences.removeValue(forKey: threadID) != nil {
            defaults.set(collaborationPreferences, forKey: Self.collaborationPreference)
        }
        guard let session = byThread.removeValue(forKey: threadID), session.threadID == threadID else { return }
        for segment in segments(for: session) {
            byThread.removeValue(forKey: segment.threadID)
            threadOwners.removeValue(forKey: segment.threadID)
        }
        providers.removeConversation(threadID)
        archivedSessions.removeAll { $0 === session }
        removeFromSidebar(session)
    }

    private func removeFromSidebar(_ session: WorkbenchSession) {
        if let threadID = session.threadID, defaults.string(forKey: Self.threadPreference) == threadID {
            defaults.removeObject(forKey: Self.threadPreference)
        }
        guard let index = sessions.firstIndex(where: { $0 === session }) else { return }
        sessions.remove(at: index)
        guard selected === session else { return }
        if sessions.isEmpty {
            newConversation(in: session.folder)
        } else {
            focus(sessions[min(index, sessions.count - 1)])
        }
    }

    func send(in session: WorkbenchSession) {
        guard canSend(in: session), let model = model(for: session) else { return }
        let profile = profile(for: session)
        let route = session.route
        let effort = reasoning(for: session)?.id ?? model.defaultEffort
        let permissions = session.permissionMode
        let collaboration = collaborationMode(for: session)
        let nativeCollaboration = collaborationModes.contains(where: { $0.id == collaboration.id })
        let input = session.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = session.folder.resolvingSymlinksInPath()
        guard Self.isDirectory(workspace) else {
            session.error = UIStrings.current.text("error.project_missing")
            return
        }
        let clientID = UUID().uuidString
        session.draft = ""
        session.error = nil
        session.runState = .starting
        session.submissionID = clientID
        session.runningRoute = route
        session.runningCollaborationModeID = collaboration.id
        session.optimisticID = clientID
        session.finalStatus = nil
        if session.entries.isEmpty && session.pendingDraftName == nil {
            session.title = ThreadSummary.shortTitle(input)
        }
        session.upsert(.init(id: clientID, kind: .user, text: input))
        moveToTop(session)

        Task {
            do {
                let engine = try await runtime(for: profile, modelID: model.id, authorized: true)
                guard session.submissionID == clientID else { return }
                session.runningConnection = engine
                let threadID = try await threadID(
                    for: session, workspace: workspace, route: route, profile: profile,
                    mode: permissions, using: engine, optimistic: clientID)
                guard session.submissionID == clientID else { return }
                session.runningThreadID = threadID
                updateAgentTask(for: session)
                var request: RPCObject = [
                    "threadId": threadID, "clientUserMessageId": clientID, "model": model.id,
                    "approvalPolicy": permissions.approvalPolicy, "sandboxPolicy": permissions.sandboxPolicy,
                    "approvalsReviewer": "user",
                    "input": [["type": "text", "text": input, "text_elements": [RPCObject]()]],
                ]
                if profile.kind == .openAI || profile.kind == .kimiCode || profile.kind == .gemini {
                    request["summary"] = "auto"
                }
                if let effort { request["effort"] = effort }
                if nativeCollaboration {
                    request["collaborationMode"] = collaboration.settings(model: model.id, effort: effort)
                }
                let response = try await engine.request("turn/start", request, timeout: 60)
                guard session.submissionID == clientID else { return }
                if session.runState == .starting {
                    guard let turn = response["turn"] as? RPCObject, let id = turn["id"] as? String else {
                        throw WorkbenchError("Codex 引擎没有返回任务编号。")
                    }
                    session.runState = .running(id)
                }
                session.agentTurnAcknowledged = true
                updateAgentTask(for: session)
            } catch {
                guard session.submissionID == clientID else { return }
                session.error = redact(error.localizedDescription)
                if session.runState == .starting {
                    session.removeUnacknowledgedInput()
                    finishRun(in: session)
                } else if session.runState.turnID != nil {
                    session.agentTurnAcknowledged = true
                    updateAgentTask(for: session)
                }
            }
        }
    }

    func interrupt(in session: WorkbenchSession) {
        guard canStop(in: session), let rpc = session.runningConnection, let thread = session.runningThreadID,
            case .running(let turn) = session.runState
        else { return }
        session.runState = .stopping(turn)
        updateAgentTask(for: session)
        Task {
            do { _ = try await rpc.request("turn/interrupt", ["threadId": thread, "turnId": turn]) } catch {
                guard session.runningConnection === rpc, session.runState == .stopping(turn) else { return }
                session.error = redact(error.localizedDescription)
                session.runState = .running(turn)
                updateAgentTask(for: session)
            }
        }
    }

    func resolve(_ approval: Approval, in session: WorkbenchSession, choosing scope: ApprovalOption.Scope) {
        guard let rpc = session.runningConnection, session.isActive,
            !session.answeringApprovalIDs.contains(approval.id),
            let current = session.approvals.first(where: { $0.id == approval.id && $0.turnID == approval.turnID }),
            let option = current.options.first(where: { $0.scope == scope })
        else { return }
        do {
            try rpc.reply(to: current.wireID, result: option.result)
            session.answeringApprovalIDs.insert(current.id)
        } catch { session.error = redact(error.localizedDescription) }
    }

    func resolve(_ input: UserInputRequest, in session: WorkbenchSession, answers: [String: String]) {
        guard let rpc = session.runningConnection, session.isActive,
            !session.answeringInputIDs.contains(input.id),
            let current = session.inputRequests.first(where: { $0.id == input.id && $0.turnID == input.turnID }),
            let response = current.response(to: answers)
        else { return }
        do {
            try rpc.reply(to: current.wireID, result: response)
            session.answeringInputIDs.insert(current.id)
        } catch { session.error = rpc.safeMessage(error.localizedDescription) }
    }

    private func preferredRoute(for profile: ProviderProfile) -> ModelRoute {
        let choices = models(for: profile)
        let preferred = profile.isOriginal ? defaultModelID : profile.defaultModel
        let id =
            preferred.isEmpty || (!choices.isEmpty && !choices.contains { $0.id == preferred })
            ? choices.first(where: \.isDefault)?.id ?? choices.first?.id ?? EnginePaths.defaultModelID : preferred
        return .init(profileID: profile.id, modelID: id)
    }

    private func segments(for session: WorkbenchSession) -> [ConversationSegment] {
        guard let root = session.threadID else { return [] }
        return providers.routes(for: root)?.segments ?? [
            .init(threadID: root, route: .init(profileID: ProviderProfile.originalID, modelID: session.modelID))
        ]
    }

    private func canReuse(_ segment: ConversationSegment, for route: ModelRoute, profile: ProviderProfile) -> Bool {
        segment.route.profileID == route.profileID && segment.keyVersion == profile.keyVersion
            && (profile.kind == .openAI || segment.route.modelID == route.modelID)
    }

    private func runtime(for profile: ProviderProfile, modelID: String, authorized: Bool) async throws
        -> CodexConnection
    {
        if profile.isOriginal {
            guard let rpc else { throw WorkbenchError(UIStrings.current.text("error.engine_offline")) }
            return rpc
        }
        let engine = try await enginePool.open(profile, modelID: modelID, authorized: authorized)
        handleNotifications(from: engine)
        return engine
    }

    private func managementRuntime(for segment: ConversationSegment) async throws -> CodexConnection {
        guard let profile = providers.profile(segment.route.profileID) else {
            throw WorkbenchError(UIStrings.current.text("error.provider_missing"))
        }
        if let owner = threadOwners[segment.threadID], owner.isOpen { return owner }
        return try await runtime(for: profile, modelID: segment.route.modelID, authorized: false)
    }

    private func resume(
        _ segment: ConversationSegment, using engine: CodexConnection, profile: ProviderProfile,
        mode: SessionPermissionMode
    ) async throws -> ThreadSummary {
        let response = try await engine.request(
            "thread/resume",
            [
                "threadId": segment.threadID, "excludeTurns": true, "modelProvider": profile.engineProviderID,
                "sandbox": mode.sandbox, "approvalPolicy": mode.approvalPolicy, "approvalsReviewer": "user",
            ])
        guard let data = response["thread"] as? RPCObject, let thread = ThreadSummary(data),
            thread.id == segment.threadID, response["modelProvider"] as? String == profile.engineProviderID
        else {
            throw WorkbenchError("无法确认对话所属的 API 引擎。")
        }
        engine.attachedThreads.insert(thread.id)
        threadOwners[thread.id] = engine
        return thread
    }

    private func threadID(
        for session: WorkbenchSession, workspace: URL, route: ModelRoute, profile: ProviderProfile,
        mode: SessionPermissionMode, using engine: CodexConnection, optimistic: String
    ) async throws -> String {
        let previous = segments(for: session)
        if let segment = previous.last, canReuse(segment, for: route, profile: profile),
            threadOwners[segment.threadID].map({ !$0.isOpen || $0 === engine }) ?? true
        {
            if !engine.attachedThreads.contains(segment.threadID) {
                _ = try await resume(segment, using: engine, profile: profile, mode: mode)
            }
            return segment.threadID
        }

        var context: PortableConversationContext?
        if !previous.isEmpty {
            let snapshot = session.transcriptSnapshot()
            let window = profile.definitions.first { $0.id == route.modelID }?.context ?? 200_000
            context = await Task.detached(priority: .userInitiated) {
                PortableConversationContext(snapshot, omitting: optimistic, contextWindow: window)
            }.value
        }
        let start = try await engine.request(
            "thread/start",
            [
                "cwd": workspace.path, "model": route.modelID, "modelProvider": profile.engineProviderID,
                "sandbox": mode.sandbox, "approvalPolicy": mode.approvalPolicy, "approvalsReviewer": "user",
            ])
        guard start["modelProvider"] as? String == profile.engineProviderID,
            let data = start["thread"] as? RPCObject, let thread = ThreadSummary(data),
            thread.folder.resolvingSymlinksInPath() == workspace
        else {
            throw WorkbenchError("Codex 引擎没有使用选定的工作目录和 API 提供方。")
        }
        do {
            for batch in context?.batches ?? [] {
                _ = try await engine.request("thread/inject_items", ["threadId": thread.id, "items": batch])
            }
            let root = session.threadID ?? thread.id
            let segment = ConversationSegment(threadID: thread.id, route: route, keyVersion: profile.keyVersion)
            try providers.record(.init(segments: previous + [segment], selection: session.route), for: root)
        } catch {
            _ = try? await engine.request("thread/delete", ["threadId": thread.id], timeout: 5)
            throw error
        }
        let isFirst = session.threadID == nil
        session.threadID = session.threadID ?? thread.id
        byThread[thread.id] = session
        engine.attachedThreads.insert(thread.id)
        threadOwners[thread.id] = engine
        session.contextLimited = context?.trimmed ?? false
        if isFirst {
            recordPermissionMode(for: session)
            recordCollaborationMode(for: session)
            if selected === session { defaults.set(thread.id, forKey: Self.threadPreference) }
            if let name = session.pendingDraftName {
                do {
                    _ = try await engine.request("thread/name/set", ["threadId": thread.id, "name": name])
                    session.pendingDraftName = nil
                } catch {
                    session.error = UIStrings.current.text("error.rename_unsaved") + redact(error.localizedDescription)
                }
            }
        }
        return thread.id
    }

    private func loadModels(_ server: CodexConnection, key: String?) async {
        async let apiIDs = visibleOpenAIModels(using: key)
        do {
            var catalog: [ModelChoice] = []
            var seen = Set<String>()
            var seenCursors = Set<String>()
            var cursor: String?
            repeat {
                var params: RPCObject = ["modelProvider": "openai", "limit": 100, "includeHidden": false]
                if let cursor { params["cursor"] = cursor }
                let page = try await server.request("model/list", params, timeout: 12)
                let choices = (page["data"] as? [RPCObject] ?? []).compactMap(ModelChoice.init)
                catalog.append(contentsOf: choices.filter { seen.insert($0.id).inserted })
                cursor = (page["nextCursor"] as? String).flatMap { seenCursors.insert($0).inserted ? $0 : nil }
            } while cursor != nil
            let visible = await apiIDs
            guard rpc === server else { return }
            openAICatalog = catalog
            models = visible.map { ids in catalog.filter { ids.contains($0.id) } } ?? catalog
            for session in sessions where model(for: session) == nil {
                session.modelID = preferredRoute(for: profile(for: session)).modelID
            }
        } catch {
            if rpc === server {
                connectionError = UIStrings.current.text("error.catalog_failed") + redact(error.localizedDescription)
            }
        }
    }

    private func visibleOpenAIModels(using key: String?) async -> Set<String>? {
        guard let key else { return nil }
        return try? await paths.availableAPIModelIDs(using: key)
    }

    private func loadConversations(append: Bool = false, archived: Bool = false) async {
        let cursor = archived ? archiveCursor : threadCursor
        guard let server = rpc, !(archived ? loadingArchives : listing), !append || cursor != nil else { return }
        if archived {
            loadingArchives = true
            archiveError = nil
        } else {
            listing = true
        }
        defer {
            if archived { loadingArchives = false } else { listing = false }
        }
        var params: RPCObject = [
            "limit": 40, "sortKey": "updated_at", "modelProviders": [String](), "archived": archived,
        ]
        if append, let cursor { params["cursor"] = cursor }
        do {
            let result = try await server.request("thread/list", params)
            guard rpc === server else { return }
            let page = (result["data"] as? [RPCObject] ?? []).compactMap(ThreadSummary.init)
            let available = Dictionary(page.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
            var additions: [WorkbenchSession] = []
            for item in page {
                let root = providers.rootThreadID(item.id)
                guard byThread[root] == nil, !deletedThreadIDs.contains(root) else { continue }
                let primary: ThreadSummary
                if let present = available[root] {
                    primary = present
                } else {
                    guard
                        let read = try? await server.request("thread/read", ["threadId": root, "includeTurns": false]),
                        let data = read["thread"] as? RPCObject, let loaded = ThreadSummary(data), loaded.id == root
                    else {
                        continue
                    }
                    primary = loaded
                }
                guard rpc === server, byThread[root] == nil else { continue }
                additions.append(addListedThread(primary, archived: archived))
            }
            let next = result["nextCursor"] as? String
            let nextCursor = append && next == cursor ? nil : next
            if archived {
                archivedSessions.append(contentsOf: additions)
                archiveCursor = nextCursor
                moreArchives = nextCursor != nil
            } else {
                sessions.append(contentsOf: additions)
                threadCursor = nextCursor
                moreConversations = nextCursor != nil
            }
        } catch {
            guard rpc === server else { return }
            if archived {
                archiveError = redact(error.localizedDescription)
            } else {
                connectionError = redact(error.localizedDescription)
            }
        }
    }

    private func addListedThread(_ thread: ThreadSummary, archived: Bool) -> WorkbenchSession {
        let stored = providers.routes(for: thread.id)
        let origin = providers.profiles.first { $0.engineProviderID == thread.providerID } ?? .original
        let selection =
            stored?.selection
            ?? .init(
                profileID: origin.id,
                modelID: thread.modelID ?? preferredRoute(for: origin).modelID)
        var efforts = effortPreferences
        if let effort = thread.effort, efforts[reasoningKey(selection)] == nil {
            efforts[reasoningKey(selection)] = effort
        }
        let session = WorkbenchSession(
            folder: thread.folder, modelID: selection.modelID,
            reasoningByModel: efforts, title: thread.title)
        session.profileID = selection.profileID
        session.threadID = thread.id
        session.isArchived = archived
        session.permissionMode =
            permissionPreferences[thread.id].flatMap(SessionPermissionMode.init(rawValue:)) ?? .workspace
        session.collaborationModeID = collaborationPreferences[thread.id] ?? CollaborationMode.standard.id
        session.loadState = .unloaded
        byThread[thread.id] = session
        for segment in stored?.segments ?? [] { byThread[segment.threadID] = session }
        return session
    }

    private func handleNotifications(from server: CodexConnection) {
        server.onEvent = { [weak self, weak server] method, params in
            guard let self, let server else { return }
            self.event(method, params, from: server)
        }
        server.onRequest = { [weak self, weak server] id, method, params in
            guard let self, let server else { return }
            self.serverRequest(id: id, method: method, params: params, from: server)
        }
        server.onDisconnect = { [weak self, weak server] explanation in
            guard let self, let server else { return }
            self.didDisconnect(server, message: explanation)
        }
    }

    private func markManagerUnavailable(_ message: String) {
        rpc = nil
        connection = .unavailable
        connectionStatus = ""
        connectionError = redact(message)
    }

    private func didDisconnect(_ server: CodexConnection, message: String) {
        if rpc === server { markManagerUnavailable(message) }
        threadOwners = threadOwners.filter { $0.value !== server }
        for session in sessions where session.runningConnection === server {
            session.settleOutput()
            session.removeUnacknowledgedInput()
            session.finalStatus = .disconnected
            session.error = server.safeMessage(message)
            finishRun(in: session)
        }
    }

    private func finishRun(in session: WorkbenchSession) {
        session.runState = .idle
        session.submissionID = nil
        session.optimisticID = nil
        session.runningConnection = nil
        session.runningThreadID = nil
        session.runningRoute = nil
        session.agentTurnAcknowledged = false
        session.clearRequests()
        updateAgentTask(for: session)
        session.runningCollaborationModeID = nil
        providerConfigurationChanged()
    }

    private func event(_ method: String, _ params: RPCObject, from server: CodexConnection) {
        guard let threadID = params["threadId"] as? String else { return }
        if method == "thread/deleted" {
            if byThread[threadID]?.threadID == threadID { applyDeletion(threadID) }
            return
        }
        guard let session = byThread[threadID] else { return }
        if threadID == session.threadID {
            switch method {
            case "thread/name/updated":
                if let name = (params["threadName"] as? String) ?? (params["name"] as? String) {
                    session.title = ThreadSummary.cleanedName(name)
                }
                return
            case "thread/archived":
                applyArchiveState(session, archived: true)
                return
            case "thread/unarchived":
                applyArchiveState(session, archived: false)
                return
            default: break
            }
        }
        guard session.runningConnection === server, session.runningThreadID == threadID else { return }
        switch method {
        case "turn/started":
            guard let turn = params["turn"] as? RPCObject, let id = turn["id"] as? String,
                id != session.lastFinishedTurnID, session.runState == .starting
            else { return }
            session.runState = .running(id)
            updateAgentTask(for: session)
        case "turn/completed":
            guard let turn = params["turn"] as? RPCObject, let id = turn["id"] as? String,
                id != session.lastFinishedTurnID,
                session.runState.turnID == id || session.runState == .starting
            else { return }
            session.settleOutput()
            session.lastFinishedTurnID = id
            session.hasUnreadResult = selected !== session
            switch turn["status"] as? String {
            case "completed": session.finalStatus = .completed
            case "interrupted": session.finalStatus = .stopped
            default:
                session.finalStatus = .failed
                let info = turn["error"] as? RPCObject
                session.error = server.safeMessage(
                    info?["message"] as? String ?? UIStrings.current.text("error.turn_failed"))
            }
            finishRun(in: session)
            releaseUnusedTranscripts()
        case "item/started", "item/completed":
            guard let data = params["item"] as? RPCObject, var item = TranscriptEntry(data) else { return }
            item.id = session.key(for: item.id, in: threadID)
            if item.kind == .answer || item.kind == .progress || item.kind == .reasoning || item.kind == .plan {
                item.isStreaming = method == "item/started"
            }
            if item.kind != .user || !session.reconcileUser(item, clientID: data["clientId"] as? String) {
                session.upsert(item)
            }
        case "item/agentMessage/delta", "item/plan/delta":
            guard let id = params["itemId"] as? String, let text = params["delta"] as? String else { return }
            session.appendDelta(
                id: session.key(for: id, in: threadID), text: text,
                kind: method == "item/plan/delta" ? .plan : .answer)
        case "item/reasoning/summaryTextDelta":
            guard let id = params["itemId"] as? String, let text = params["delta"] as? String,
                let part = params["summaryIndex"] as? Int
            else { return }
            session.appendDelta(id: session.key(for: id, in: threadID), text: text, summaryIndex: part)
        case "serverRequest/resolved":
            if let id = params["requestId"] { session.clearRequest(Approval.key(for: id)) }
            updateAgentTask(for: session)
        default: break
        }
    }

    private func serverRequest(id: Any, method: String, params: RPCObject, from server: CodexConnection) {
        guard let thread = params["threadId"] as? String, let session = byThread[thread], session.isActive,
            session.runningConnection === server, session.runningThreadID == thread,
            let turn = params["turnId"] as? String,
            session.runState.turnID == nil || session.runState.turnID == turn
        else {
            server.unsupported(id, method: method)
            return
        }
        if method == "item/tool/requestUserInput", let input = UserInputRequest(wireID: id, params: params) {
            if !session.inputRequests.contains(where: { $0.id == input.id }) { session.inputRequests.append(input) }
        } else if let approval = Approval(
            wireID: id, method: method, params: params,
            itemDetail: (params["itemId"] as? String).flatMap { session.entry(session.key(for: $0, in: thread)) }?
                .detail),
            !approval.options.isEmpty
        {
            if !session.approvals.contains(where: { $0.id == approval.id }) { session.approvals.append(approval) }
        } else {
            server.unsupported(id, method: method)
            return
        }
        updateAgentTask(for: session)
    }

    func callAgentTool(_ name: String, arguments: RPCObject) async throws -> RPCObject {
        switch name {
        case "dispatch_task": return try await dispatchAgentTask(arguments)
        case "task_status": return try await agentTaskStatus(arguments)
        case "cancel_task": return try cancelAgentTask(arguments)
        case "list_models": return try await agentModels(arguments)
        default: throw WorkbenchError("未知的工作台操作。")
        }
    }

    private func dispatchAgentTask(_ arguments: RPCObject) async throws -> RPCObject {
        let input: AgentDispatchArguments = try decodeAgentArguments(
            arguments, keys: AgentDispatchArguments.CodingKeys.allCases.map(\.rawValue))
        let prompt = input.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty, prompt.utf8.count <= 64 * 1024,
            input.requestID.map({ !$0.isEmpty && $0.utf8.count <= 128 }) != false
        else {
            throw WorkbenchError("请给出不超过 64 KB 的任务提示。request_id 可包含 1–128 字节。")
        }
        let id = AgentTaskStore.id(for: input.requestID)
        let fingerprint = try AgentTaskStore.hash(
            JSONSerialization.data(withJSONObject: arguments, options: .sortedKeys))
        func duplicate() throws -> RPCObject? {
            guard let record = try agentTasks.existing(id) else { return nil }
            guard record.fingerprint == fingerprint else {
                throw WorkbenchError("此 request_id 已用于其他任务。")
            }
            return record.response()
        }
        if let record = try duplicate() { return record }
        try await waitForAgentEngine()
        if let record = try duplicate() { return record }

        let folder: URL
        if let workspace = input.workspace {
            guard workspace.hasPrefix("/"), workspace.utf8.count <= 4096, !workspace.utf8.contains(0) else {
                throw WorkbenchError("workspace 需要是本机文件夹的绝对路径。")
            }
            folder = URL(fileURLWithPath: workspace, isDirectory: true)
        } else {
            folder = paths.workspace
        }
        let workingFolder = folder.resolvingSymlinksInPath()
        guard Self.isDirectory(workingFolder) else {
            throw WorkbenchError(UIStrings.current.text("error.mcp_workspace"))
        }
        let profileID = input.provider ?? providers.defaultProfileID
        guard let profile = providers.profile(profileID), providers.configured(profile) else {
            throw WorkbenchError(UIStrings.current.text("error.mcp_provider"))
        }
        let modelID = input.model ?? preferredRoute(for: profile).modelID
        guard let model = models(for: profile).first(where: { $0.id == modelID }) else {
            throw WorkbenchError(UIStrings.current.text("error.mcp_model"))
        }
        if let effort = input.effort, !model.reasoningChoices.contains(where: { $0.id == effort }) {
            throw WorkbenchError(UIStrings.current.text("error.mcp_effort"))
        }
        let collaborationID = input.mode ?? CollaborationMode.standard.id
        guard
            collaborationID == CollaborationMode.standard.id
                || collaborationModes.contains(where: { $0.id == collaborationID })
        else { throw WorkbenchError(UIStrings.current.text("mode.unavailable", collaborationID)) }
        guard let permission = [SessionPermissionMode.workspace, .readOnly].first(where: permissionModes.contains)
        else {
            throw WorkbenchError("当前配置没有可供 MCP 派遣的工作区权限。")
        }

        let session = WorkbenchSession(folder: workingFolder, modelID: modelID, reasoningByModel: effortPreferences)
        session.profileID = profile.id
        session.permissionMode = permission
        session.collaborationModeID = collaborationID
        if let effort = input.effort { session.reasoningByModel[reasoningKey(session.route)] = effort }
        session.draft = prompt
        session.agentTaskID = id
        let record = AgentTaskRecord(
            id: id, instance: agentTasks.instance, fingerprint: fingerprint,
            provider: profile.id, model: modelID)
        try agentTasks.create(record)
        sessions.insert(session, at: 0)
        send(in: session)
        if !session.isActive {
            agentTasks.update(
                id, status: .failed, sessionID: nil, answer: nil,
                error: session.error ?? "工作台未能启动任务。")
        }
        var results = try agentTasks.existing(id)?.response() ?? record.response()
        results["provider"] = profile.id
        results["model"] = modelID
        results["mode"] = collaborationID
        return results
    }

    private func agentTaskStatus(_ arguments: RPCObject) async throws -> RPCObject {
        let query: AgentStatusArguments = try decodeAgentArguments(
            arguments, keys: AgentStatusArguments.CodingKeys.allCases.map(\.rawValue))
        let wait = query.waitSeconds ?? 0
        let offset = query.offset ?? 0
        let limit = query.maxChars ?? 1600
        guard (0...20).contains(wait), (0...65_536).contains(offset), (0...6000).contains(limit),
            query.afterRevision.map({ $0 > 0 }) != false
        else {
            throw WorkbenchError("状态查询参数超出范围。")
        }
        let deadline = ContinuousClock.now + .seconds(wait)
        while true {
            guard let record = try agentTasks.existing(query.taskID) else {
                throw WorkbenchError(UIStrings.current.text("error.mcp_task_missing"))
            }
            if record.status.isFinished || record.status == .waitingApproval || record.status == .waitingInput
                || query.afterRevision.map({ $0 != record.revision }) == true || ContinuousClock.now >= deadline
            {
                return record.response(after: query.afterRevision, offset: offset, limit: limit)
            }
            try await Task.sleep(for: .milliseconds(150))
        }
    }

    private func cancelAgentTask(_ arguments: RPCObject) throws -> RPCObject {
        guard arguments.count == 1, let id = arguments["task_id"] as? String,
            let record = try agentTasks.existing(id)
        else { throw WorkbenchError(UIStrings.current.text("error.mcp_task_missing")) }
        guard !record.status.isFinished,
            let session = sessions.first(where: { $0.agentTaskID == id && $0.isActive })
        else { return record.response() }
        if session.runState == .starting, session.runningThreadID == nil {
            session.removeUnacknowledgedInput()
            session.finalStatus = .stopped
            finishRun(in: session)
        } else if session.runState == .starting || canStop(in: session) {
            agentStopRequests.insert(id)
            updateAgentTask(for: session)
        }
        return try agentTasks.existing(id)?.response() ?? record.response()
    }

    private func agentModels(_ arguments: RPCObject) async throws -> RPCObject {
        let requested = arguments["provider"] as? String
        guard arguments.isEmpty || (arguments.count == 1 && requested != nil) else { throw WorkbenchError("无效的供应商查询。") }
        try await waitForAgentEngine()
        let configured = providers.profiles.filter {
            providers.configured($0) && (requested == nil || $0.id == requested)
        }
        let values: [RPCObject] = configured.map { profile in
            let models = models(for: profile)
            var row: RPCObject = [
                "id": profile.id, "name": profile.name, "default_model": preferredRoute(for: profile).modelID,
            ]
            if requested == nil {
                row["models"] = models.map(\.id)
            } else {
                row["models"] = models.map { ["id": $0.id, "efforts": $0.reasoningChoices.map(\.id)] as RPCObject }
            }
            return row
        }
        let modes = collaborationModes.isEmpty ? [CollaborationMode.standard.id] : collaborationModes.map(\.id)
        return ["default_provider": providers.defaultProfileID, "providers": values, "modes": modes]
    }

    private func waitForAgentEngine() async throws {
        let deadline = ContinuousClock.now + .seconds(12)
        while connection == .connecting && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(150))
        }
        guard connection == .ready else { throw WorkbenchError(connectionError ?? "工作台引擎尚未就绪。") }
    }

    private func decodeAgentArguments<T: Decodable>(_ arguments: RPCObject, keys: [String]) throws -> T {
        guard Set(arguments.keys).isSubset(of: Set(keys)) else { throw WorkbenchError("MCP 操作包含未知参数。") }
        do {
            return try JSONDecoder().decode(T.self, from: JSONSerialization.data(withJSONObject: arguments))
        } catch { throw WorkbenchError("MCP 参数缺失或类型不正确。") }
    }

    private func updateAgentTask(for session: WorkbenchSession) {
        guard let id = session.agentTaskID else { return }
        let stopping = agentStopRequests.contains(id)
        if stopping, session.agentTurnAcknowledged, canStop(in: session) {
            agentStopRequests.remove(id)
            interrupt(in: session)
            return
        }
        let status: AgentTaskStatus
        switch session.runState {
        case .starting: status = stopping ? .stopping : .starting
        case .running:
            if stopping {
                status = .stopping
            } else if !session.inputRequests.isEmpty {
                status = .waitingInput
            } else {
                status = session.approvals.isEmpty ? .running : .waitingApproval
            }
        case .stopping: status = .stopping
        case .idle:
            agentStopRequests.remove(id)
            switch session.finalStatus {
            case .completed: status = .completed
            case .stopped: status = .cancelled
            case .disconnected: status = .interrupted
            default: status = .failed
            }
        }
        let plan =
            status == .completed && session.runningCollaborationModeID == "plan" ? session.proposedPlan?.text : nil
        let answer = status.isFinished ? plan ?? session.entries.last(where: { $0.kind == .answer })?.text : nil
        agentTasks.update(
            id, status: status, sessionID: session.threadID,
            answer: answer.map(redact), error: session.error.map(redact))
        if status.isFinished { session.agentTaskID = nil }
    }

    private func moveToTop(_ session: WorkbenchSession) {
        guard let index = sessions.firstIndex(where: { $0 === session }), index > 0 else { return }
        sessions.remove(at: index)
        sessions.insert(session, at: 0)
    }
    private func recordFolder(_ folder: URL) { defaults.set(folder.path, forKey: "workspacePath") }
    private func recordPermissionMode(for session: WorkbenchSession) {
        guard let threadID = session.threadID else { return }
        permissionPreferences[threadID] = session.permissionMode == .workspace ? nil : session.permissionMode.rawValue
        defaults.set(permissionPreferences, forKey: Self.permissionPreference)
    }
    private func recordCollaborationMode(for session: WorkbenchSession) {
        guard let threadID = session.threadID else { return }
        let id = session.collaborationModeID
        collaborationPreferences[threadID] = id == CollaborationMode.standard.id ? nil : id
        defaults.set(collaborationPreferences, forKey: Self.collaborationPreference)
    }
    private static func isDirectory(_ location: URL) -> Bool {
        (try? location.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }
}
