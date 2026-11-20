import Foundation

/// Feed validated provider credentials through a private pipe to the same signed
/// executable that later reads them. Keys never appear in command-line arguments.
@MainActor
enum ProviderKeyImport {
    private struct Entry: Decodable {
        let provider: ProviderKind
        let key: String
        let region: ProviderProfile.Region?
        let models: [String]
    }

    static func run() -> Int32 {
        guard let data = try? readInput(), data.count <= 32_768,
            let entries = try? JSONDecoder().decode([Entry].self, from: data),
            !entries.isEmpty,
            Set(entries.map(\.provider)).count == entries.count,
            entries.allSatisfy({ $0.provider.builtInProfileID != nil })
        else {
            diagnose("供应商导入数据无效。")
            return 1
        }
        let keys = KeychainProfileKeys()
        let configuration = ProviderConfiguration(defaults: .standard, keys: keys)
        var failed = false
        for item in entries {
            guard let id = item.provider.builtInProfileID,
                var profile = configuration.profile(id), profile.kind == item.provider
            else {
                diagnose("\(item.provider.title) 缺少内置配置。")
                failed = true
                continue
            }
            let available = profile.kind.builtInModels.filter { item.models.contains($0.id) }
            guard let fallback = available.first else {
                diagnose("\(item.provider.title) 没有通过验证的受支持模型。")
                failed = true
                continue
            }
            if let region = item.region { profile.region = region }
            if profile.kind == .gemini { profile.verifiedModelIDs = available.map(\.id) }
            if !available.contains(where: { $0.id == profile.defaultModel }) { profile.defaultModel = fallback.id }
            do {
                let firstGeminiImport = profile.kind == .gemini && !configuration.configured(profile)
                try configuration.save(profile, key: item.key, activateOnLaunch: firstGeminiImport)
                guard try keys.read(id) == item.key else {
                    throw WorkbenchError("钥匙串回读不一致。")
                }
                print("\(item.provider.rawValue) saved")
            } catch {
                diagnose("\(item.provider.title) 配置未验证成功。")
                failed = true
            }
        }
        return failed ? 2 : 0
    }

    static func restore() -> Int32 {
        let keys = KeychainProfileKeys()
        let configuration = ProviderConfiguration(defaults: .standard, keys: keys)
        guard let data = try? readInput(), data.count <= 32_768,
            let entries = try? JSONDecoder().decode([String: String].self, from: data),
            !entries.isEmpty,
            entries.allSatisfy({ id, key in
                guard let profile = configuration.profile(id), !profile.isOriginal,
                    configuration.configured(profile)
                else { return false }
                return (8...8192).contains(key.utf8.count) && !key.contains(where: \.isWhitespace)
            })
        else { return 1 }
        var failed = false
        for (id, key) in entries.sorted(by: { $0.key < $1.key }) {
            do {
                try keys.write(key, id: id)
                guard try keys.read(id) == key else {
                    failed = true
                    continue
                }
                print("\(id) ready")
            } catch {
                diagnose("\(id): \(error.localizedDescription)")
                failed = true
            }
        }
        return failed ? 2 : 0
    }

    private static func readInput() throws -> Data {
        var data = Data()
        while data.count < 32_769 {
            let limit = min(4096, 32_769 - data.count)
            guard let chunk = try FileHandle.standardInput.read(upToCount: limit), !chunk.isEmpty else { break }
            data.append(chunk)
        }
        return data
    }

    private static func diagnose(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}
