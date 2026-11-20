import Foundation

@MainActor
final class ProviderEnginePool {
    private struct Identity: Hashable {
        let profileID: String
        let endpoint: String
        let version: UUID?
        let models: [String]
        let authorized: Bool
    }

    private let paths: EnginePaths
    private let configuration: ProviderConfiguration
    private var engines: [Identity: CodexConnection] = [:]
    private var starting: [Identity: Task<CodexConnection, Error>] = [:]
    private var closed = false

    init(paths: EnginePaths, configuration: ProviderConfiguration) {
        self.paths = paths
        self.configuration = configuration
    }

    func open(_ profile: ProviderProfile, modelID: String, authorized: Bool) async throws -> CodexConnection {
        guard !closed else { throw WorkbenchError(UIStrings.current.text("error.engine_closed")) }
        let endpoint = paths.providerTestEndpoints[profile.kind] ?? profile.endpoint
        let identity = Identity(
            profileID: profile.id, endpoint: endpoint, version: profile.keyVersion,
            models: profile.customModels, authorized: authorized)
        if !authorized {
            let active = Identity(
                profileID: profile.id, endpoint: endpoint, version: profile.keyVersion,
                models: profile.customModels, authorized: true)
            if let engine = engines[active], engine.isOpen { return engine }
        }
        if let engine = engines[identity], engine.isOpen { return engine }
        if let task = starting[identity] { return try await task.value }

        let task = Task { @MainActor in
            let key = authorized ? try self.configuration.secret(for: profile, using: self.paths) : nil
            let catalog = try self.catalog(for: profile)
            var provider = DirectEngineProvider(
                id: profile.engineProviderID, name: profile.kind.title, kind: profile.kind,
                endpoint: endpoint, modelID: modelID, catalog: catalog, key: key
            )
            if profile.kind == .gemini, let key, let upstream = URL(string: endpoint) {
                let (transport, local) = try await GeminiTransport.start(
                    key: key, upstream: upstream, models: profile.definitions)
                provider.endpoint = local.absoluteString
                provider.key = transport.token
                provider.transport = transport
            }
            let runtime = try CodexConnection(paths: self.paths, provider: provider)
            do {
                try await Self.initialize(runtime, paths: self.paths)
                try Task.checkCancellation()
                return runtime
            } catch {
                runtime.stop()
                throw error
            }
        }
        starting[identity] = task
        defer { starting.removeValue(forKey: identity) }
        let engine = try await task.value
        guard !closed else {
            engine.stop()
            throw WorkbenchError(UIStrings.current.text("error.engine_closed"))
        }
        engines[identity] = engine
        return engine
    }

    func reapChangedProfiles(retaining inUse: [CodexConnection]) {
        for (identity, engine) in Array(engines) {
            guard let current = configuration.profile(identity.profileID) else { continue }
            let endpoint = paths.providerTestEndpoints[current.kind] ?? current.endpoint
            let stale =
                identity.version != current.keyVersion || identity.endpoint != endpoint
                || identity.models != current.customModels || !engine.isOpen
            guard stale, !inUse.contains(where: { $0 === engine }) else { continue }
            engines.removeValue(forKey: identity)
            engine.stop()
        }
    }

    func stopAll() {
        closed = true
        for task in starting.values { task.cancel() }
        starting.removeAll()
        for engine in engines.values { engine.stop() }
        engines.removeAll()
    }

    private func catalog(for profile: ProviderProfile) throws -> URL? {
        if profile.kind == .openAI { return paths.modelCatalog }
        let url = paths.state.appendingPathComponent("models-" + profile.id + ".json")
        let entries = profile.definitions.enumerated().map {
            $0.element.engineMetadata(order: $0.offset, kind: profile.kind)
        }
        if entries.isEmpty { throw WorkbenchError("该供应商缺少模型目录。") }
        let data = try JSONSerialization.data(withJSONObject: ["models": entries], options: [.sortedKeys])
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        return url
    }

    static func initialize(_ server: CodexConnection, paths: EnginePaths) async throws {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.11"
        let info = try await server.request(
            "initialize",
            [
                "clientInfo": ["name": "local_api_workbench", "title": "UniCodex", "version": version],
                "capabilities": ["experimentalApi": true, "requestAttestation": false],
            ])
        guard let runtime = info["codexHome"] as? String, runtime.hasPrefix("/"),
            URL(fileURLWithPath: runtime, isDirectory: true).resolvingSymlinksInPath().path
                == paths.codexHome.resolvingSymlinksInPath().path
        else {
            throw WorkbenchError("Codex 引擎没有使用工作台的独立目录。")
        }
        try server.notify("initialized")
    }
}
