import Foundation
import Observation

enum ProviderKind: String, Codable, CaseIterable, Identifiable {
    case openAI, deepSeek, kimiCode, gemini, compatible

    var id: Self { self }
    var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .kimiCode: "Kimi Code"
        case .gemini: "Google Gemini"
        case .compatible: UIStrings.current.text("provider.compatible")
        }
    }

    var builtInProfileID: String? {
        switch self {
        case .deepSeek: "deepseek-default"
        case .kimiCode: "kimi-default"
        case .gemini: "gemini-default"
        case .openAI, .compatible: nil
        }
    }

    var builtInModels: [ProviderModel] {
        switch self {
        case .openAI, .compatible: []
        case .deepSeek:
            [
                .init(id: "deepseek-flash", name: "DeepSeek Flash", context: 1_048_576, image: true),
                .init(id: "deepseek-v4-pro", name: "DeepSeek V4 Pro", context: 1_048_576),
            ]
        case .kimiCode:
            [
                .init(id: "k3.1-pro", name: "K3.1 Pro", context: 1_048_576, image: true),
                .init(id: "k3.1-pro-highspeed", name: "K3.1 Pro Highspeed", context: 1_048_576, image: true),
                .init(id: "k3", name: "K3", context: 1_048_576, image: true),
                .init(id: "k3-256k", name: "K3 256K", context: 262_144, image: true),
                .init(id: "kimi-for-coding", name: "K2.8 Preview", context: 262_144, image: true, defaultEffort: "max"),
                .init(
                    id: "kimi-for-coding-highspeed", name: "K2.7 Code Highspeed", context: 262_144,
                    image: true, efforts: []),
            ]
        case .gemini:
            [
                .gemini("gemini-3.8-flash", "Gemini 3.8 Flash"),
                .gemini(
                    "gemini-4-hydrogen", "Gemini 4 Hydrogen", defaultEffort: "high",
                    efforts: ["low", "medium", "high", "xhigh"]),
                .gemini(
                    "gemini-4-neon", "Gemini 4 Neon", defaultEffort: "high",
                    efforts: ["low", "medium", "high", "xhigh"]),
                .gemini("gemini-4-carbon", "Gemini 4 Carbon"),
                .gemini("gemini-4-argon", "Gemini 4 Argon"),
                .gemini("gemini-3.6-flash", "Gemini 3.6 Flash", efforts: ["minimal", "low", "medium", "high"]),
                .gemini(
                    "gemini-3.1-flash-lite", "Gemini 3.1 Flash-Lite", defaultEffort: "minimal",
                    efforts: ["minimal", "low", "medium", "high"]),
            ]
        }
    }
}

struct ProviderModel {
    let id: String
    let name: String
    let context: Int
    var image = false
    var defaultEffort = "high"
    var efforts = ["low", "high", "max"]

    static func gemini(
        _ id: String, _ name: String, defaultEffort: String = "medium",
        efforts: [String] = ["low", "medium", "high"]
    ) -> Self {
        .init(id: id, name: name, context: 1_048_576, image: true, defaultEffort: defaultEffort, efforts: efforts)
    }

    var choice: ModelChoice {
        ModelChoice(id: id, name: name, defaultEffort: efforts.isEmpty ? nil : defaultEffort, efforts: efforts)
    }

    func engineMetadata(order: Int, kind: ProviderKind) -> RPCObject {
        [
            "slug": id, "display_name": name, "description": name,
            "visibility": "list", "supported_in_api": true, "priority": order,
            "prefer_websockets": false, "shell_type": "shell_command",
            "apply_patch_tool_type": "freeform", "supports_parallel_tool_calls": true,
            "base_instructions":
                "You are a coding agent working with the user in a shared workspace. Use the provided tools to inspect, modify and verify the project. Follow existing project instructions. Preserve unrelated changes and report what was verified.",
            "default_reasoning_level": efforts.isEmpty ? "medium" : defaultEffort,
            "supported_reasoning_levels": efforts.map { ["effort": $0, "description": $0] },
            "supports_reasoning_summaries": kind == .kimiCode || kind == .gemini,
            "default_reasoning_summary": "none",
            "support_verbosity": false, "experimental_supported_tools": [String](),
            "truncation_policy": ["mode": "bytes", "limit": 10_000] as RPCObject,
            "context_window": context, "max_context_window": context, "effective_context_window_percent": 95,
            "input_modalities": image ? ["text", "image"] : ["text"],
        ]
    }
}

struct ProviderProfile: Codable, Identifiable, Equatable {
    enum Region: String, Codable, CaseIterable, Identifiable {
        case china, global
        var id: Self { self }
        var title: String {
            self == .china ? UIStrings.current.text("provider.china") : UIStrings.current.text("provider.global")
        }
    }

    static let originalID = "openai-original"
    static let original = ProviderProfile(
        id: originalID, name: "OpenAI", kind: .openAI,
        defaultModel: EnginePaths.defaultModelID)

    let id: String
    var name: String
    let kind: ProviderKind
    var region: Region = .china
    var customURL = ""
    var customModels: [String] = []
    var defaultModel: String
    var keyVersion: UUID?
    var verifiedModelIDs: [String]?

    init(id: String = UUID().uuidString.lowercased(), name: String, kind: ProviderKind, defaultModel: String = "") {
        self.id = id
        self.name = name
        self.kind = kind
        self.defaultModel = defaultModel
    }

    var isOriginal: Bool { id == Self.originalID }
    var engineProviderID: String {
        isOriginal ? "openai" : "workbench_" + id.replacingOccurrences(of: "-", with: "_")
    }

    var endpoint: String {
        switch kind {
        case .openAI: "https://api.openai.com/v1"
        case .deepSeek: "https://api.deepseek.com"
        case .kimiCode: region == .china ? "https://api.kimi.com/coding/v1" : "https://api.kimi.ai/coding/v1"
        case .gemini: GeminiAPI.baseURL.absoluteString
        case .compatible: customURL
        }
    }

    var definitions: [ProviderModel] {
        if kind == .compatible {
            return customModels.map { ProviderModel(id: $0, name: $0, context: 32_768, efforts: []) }
        }
        if kind == .gemini, let verifiedModelIDs {
            return kind.builtInModels.filter { verifiedModelIDs.contains($0.id) }
        }
        return kind.builtInModels
    }

    var catalog: [ModelChoice] { definitions.map(\.choice) }

    func validated() throws -> Self {
        var value = self
        value.name = ThreadSummary.cleanedName(name)
        guard !value.name.isEmpty, value.name.count <= 50 else {
            throw WorkbenchError(UIStrings.current.text("error.profile_name"))
        }
        if kind == .compatible {
            value.customURL = customURL.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let parts = URLComponents(string: value.customURL), parts.scheme?.lowercased() == "https",
                let host = parts.host, !host.isEmpty, parts.url != nil, parts.user == nil,
                parts.password == nil, parts.query == nil, parts.fragment == nil
            else {
                throw WorkbenchError(UIStrings.current.text("error.profile_endpoint"))
            }
            var seen = Set<String>()
            value.customModels = customModels.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && seen.insert($0).inserted }
            guard !value.customModels.isEmpty, value.customModels.count <= 50,
                value.customModels.allSatisfy({ $0.utf8.count <= 150 && !$0.contains(where: \.isWhitespace) })
            else {
                throw WorkbenchError(UIStrings.current.text("error.profile_models"))
            }
        }
        if kind != .openAI {
            guard let first = value.definitions.first else {
                throw WorkbenchError(UIStrings.current.text("error.profile_models_required"))
            }
            if !value.definitions.contains(where: { $0.id == value.defaultModel }) { value.defaultModel = first.id }
        }
        return value
    }
}

struct ModelRoute: Codable, Equatable {
    let profileID: String
    let modelID: String
}

struct ConversationSegment: Codable, Equatable {
    let threadID: String
    let route: ModelRoute
    var keyVersion: UUID? = nil
}

struct ConversationRoutes: Codable {
    var segments: [ConversationSegment]
    var selection: ModelRoute
}

protocol ProfileKeyStore {
    func read(_ id: String) throws -> String
    func write(_ key: String, id: String) throws
    func remove(_ id: String) throws
}

struct KeychainProfileKeys: ProfileKeyStore {
    func read(_ id: String) throws -> String {
        let bytes = try invoke("read", id: id)
        guard let value = String(data: bytes, encoding: .utf8), !value.isEmpty else {
            throw WorkbenchError(UIStrings.current.text("keychain.invalid"))
        }
        return value
    }

    func write(_ key: String, id: String) throws {
        _ = try invoke("write", id: id, input: Data(key.utf8))
    }

    func remove(_ id: String) throws {
        _ = try invoke("delete", id: id)
    }

    func restore(_ id: String) throws {
        _ = try invoke("restore", id: id)
    }

    @discardableResult
    private func invoke(_ operation: String, id: String, input: Data? = nil) throws -> Data {
        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/UniCodexCredentials")
        let process = Process()
        let output = Pipe()
        let incoming = Pipe()
        process.executableURL = helper
        process.arguments = [operation, id]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = incoming
        try process.run()
        if let input { try incoming.fileHandleForWriting.write(contentsOf: input) }
        try incoming.fileHandleForWriting.close()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        switch process.terminationStatus {
        case 0: return bytes
        case 3: throw WorkbenchError(UIStrings.current.text("keychain.restore.required"))
        case 4: throw WorkbenchError(UIStrings.current.text("keychain.locked"))
        default: throw WorkbenchError(UIStrings.current.text("keychain.unavailable"))
        }
    }
}

@Observable @MainActor
final class ProviderConfiguration {
    private struct Stored: Codable {
        var profiles: [ProviderProfile] = [.original]
        var defaultProfileID = ProviderProfile.originalID
        var conversations: [String: ConversationRoutes] = [:]
    }
    private static let storageKey = "directProviderConfiguration"
    private static let pendingGeminiKey = "pendingGeminiProfile"
    private(set) var profiles: [ProviderProfile]
    private(set) var defaultProfileID: String
    private(set) var hasOriginalKey = false
    @ObservationIgnored private var conversations: [String: ConversationRoutes]
    @ObservationIgnored private var backingRoots: [String: String] = [:]
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keys: ProfileKeyStore
    @ObservationIgnored private let decoded: Bool

    init(defaults: UserDefaults, keys: ProfileKeyStore) {
        self.defaults = defaults
        self.keys = keys
        let file = defaults.data(forKey: Self.storageKey)
        let saved = file.flatMap { try? JSONDecoder().decode(Stored.self, from: $0) }
        decoded = file == nil || saved != nil
        let state = saved ?? Stored()
        let missing = ProviderKind.allCases.compactMap { kind -> ProviderProfile? in
            guard let id = kind.builtInProfileID, let model = kind.builtInModels.first,
                !state.profiles.contains(where: { $0.id == id })
            else { return nil }
            return ProviderProfile(id: id, name: kind.title, kind: kind, defaultModel: model.id)
        }
        profiles = state.profiles + missing
        defaultProfileID = state.defaultProfileID
        conversations = state.conversations
        rebuildBackingRoots()
        if decoded, let data = defaults.data(forKey: Self.pendingGeminiKey),
            let pending = try? JSONDecoder().decode(ProviderProfile.self, from: data),
            pending.kind == .gemini, pending.id == ProviderKind.gemini.builtInProfileID, pending.keyVersion != nil,
            let index = profiles.firstIndex(where: { $0.id == pending.id && $0.kind == .gemini && $0.keyVersion == nil }
            )
        {
            profiles[index] = pending
            persist()
            defaults.removeObject(forKey: Self.pendingGeminiKey)
        }
    }

    func noteOriginalKey(available: Bool) { hasOriginalKey = available }
    func profile(_ id: String) -> ProviderProfile? { profiles.first { $0.id == id } }
    func configured(_ profile: ProviderProfile) -> Bool {
        profile.isOriginal ? hasOriginalKey : profile.keyVersion != nil
    }
    func routes(for threadID: String) -> ConversationRoutes? { conversations[threadID] }

    func rootThreadID(_ id: String) -> String { backingRoots[id] ?? id }

    func save(_ update: ProviderProfile, key: String?, activateOnLaunch: Bool = false) throws {
        guard decoded else { throw WorkbenchError("无法读取已有供应商配置。") }
        var profile = try update.validated()
        let exists = self.profile(profile.id)
        if activateOnLaunch {
            guard profile.kind == .gemini, profile.id == ProviderKind.gemini.builtInProfileID,
                exists?.keyVersion == nil, key != nil
            else {
                throw WorkbenchError("此供应商配置不能暂存。")
            }
        }
        // A saved credential is bound to the destination entered at creation.
        if let exists, exists.endpoint != profile.endpoint, exists.keyVersion != nil, key == nil {
            throw WorkbenchError(UIStrings.current.text("error.profile_endpoint_key"))
        }
        if let key {
            let value = key.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !profile.isOriginal, value.utf8.count >= 8, value.utf8.count <= 8192,
                !value.contains(where: \.isWhitespace)
            else { throw WorkbenchError(UIStrings.current.text("error.key_invalid")) }
            try keys.write(value, id: profile.id)
            profile.keyVersion = UUID()
        }
        if activateOnLaunch {
            // An older running version can still save its conversation routes.
            // Use a distinct preference until the upgraded application launches.
            let pending = try JSONEncoder().encode(profile)
            defaults.set(pending, forKey: Self.pendingGeminiKey)
            return
        }
        if let index = profiles.firstIndex(where: { $0.id == profile.id }) {
            profiles[index] = profile
        } else {
            profiles.append(profile)
        }
        persist()
    }

    func clearKey(for id: String) throws {
        guard decoded, let index = profiles.firstIndex(where: { $0.id == id && !$0.isOriginal }) else { return }
        try keys.remove(id)
        profiles[index].keyVersion = nil
        if defaultProfileID == id { defaultProfileID = ProviderProfile.originalID }
        persist()
    }

    func setDefault(_ id: String) {
        guard decoded, let profile = profile(id), configured(profile) else { return }
        defaultProfileID = id
        persist()
    }

    func secret(for profile: ProviderProfile, using paths: EnginePaths) throws -> String {
        if profile.isOriginal { return try paths.credential() }
        guard let current = self.profile(profile.id), current == profile, configured(profile) else {
            throw WorkbenchError(UIStrings.current.text("error.key_required", profile.name))
        }
        return try keys.read(profile.id)
    }

    func record(_ routes: ConversationRoutes, for root: String) throws {
        guard decoded else { throw WorkbenchError("无法保存会话的供应商接续记录。") }
        conversations[root] = routes
        rebuildBackingRoots()
        persist()
    }

    func removeConversation(_ root: String) {
        guard decoded else { return }
        conversations.removeValue(forKey: root)
        rebuildBackingRoots()
        persist()
    }

    private func rebuildBackingRoots() {
        backingRoots.removeAll(keepingCapacity: true)
        for (root, route) in conversations {
            for segment in route.segments where segment.threadID != root { backingRoots[segment.threadID] = root }
        }
    }

    private func persist() {
        let state = Stored(profiles: profiles, defaultProfileID: defaultProfileID, conversations: conversations)
        if let data = try? JSONEncoder().encode(state) { defaults.set(data, forKey: Self.storageKey) }
    }
}
