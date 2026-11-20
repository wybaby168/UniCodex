import Foundation
import SwiftUI

struct UIStrings: Equatable {
    static let preference = "interfaceLanguage"
    static let system = "system"
    let selection: String

    static var current: UIStrings {
        UIStrings(selection: UserDefaults.standard.string(forKey: preference) ?? system)
    }

    private static let bundles: [String: Bundle] = {
        guard let resources = Bundle.main.resourceURL,
            let folders = try? FileManager.default.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)
        else { return [:] }
        return folders.reduce(into: [:]) { result, folder in
            guard folder.pathExtension == "lproj",
                FileManager.default.fileExists(atPath: folder.appendingPathComponent("Localizable.strings").path),
                let bundle = Bundle(url: folder)
            else { return }
            result[folder.deletingPathExtension().lastPathComponent] = bundle
        }
    }()

    static let availableLanguages = bundles.keys.sorted {
        languageName($0).localizedStandardCompare(languageName($1)) == .orderedAscending
    }

    static func languageName(_ id: String) -> String {
        let language = Locale(identifier: id)
        return language.localizedString(forIdentifier: id) ?? id
    }

    private var languageID: String {
        if Self.bundles[selection] != nil { return selection }
        return Bundle.preferredLocalizations(from: Self.availableLanguages, forPreferences: Locale.preferredLanguages)
            .first ?? "en"
    }

    var locale: Locale {
        selection == Self.system ? .autoupdatingCurrent : Locale(identifier: languageID)
    }

    func text(_ key: String, _ arguments: CVarArg...) -> String {
        guard !key.isEmpty else { return "" }
        let fallback = Self.bundles["en"]?.localizedString(forKey: key, value: key, table: nil) ?? key
        let format = Self.bundles[languageID]?.localizedString(forKey: key, value: fallback, table: nil) ?? fallback
        return arguments.isEmpty ? format : String(format: format, locale: locale, arguments: arguments)
    }

    func activityTitle(_ title: String) -> String {
        if let key = Self.activityKeys[title] { return text(key) }
        if title.hasPrefix("命令退出（"), title.hasSuffix("）"),
            let exitCode = Int(title.dropFirst(5).dropLast())
        {
            return text("transcript.exit", exitCode)
        }
        if title.hasPrefix("工具 · ") { return text("transcript.tool", String(title.dropFirst(5))) }
        return title
    }

    private static let activityKeys = [
        "命令已拒绝": "transcript.command_denied", "命令失败": "transcript.command_failed",
        "命令已完成": "transcript.command_done", "运行命令": "approval.run",
        "文件修改": "transcript.file_change", "文件修改失败": "transcript.file_change_failed",
    ]
}

extension EnvironmentValues {
    @Entry var uiStrings = UIStrings.current
}
