import Foundation
import Observation

struct UniCodexRelease {
    private struct Listing: Decodable {
        let tagName: String
        let draft: Bool
        let prerelease: Bool
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case draft, prerelease, assets
        }
    }

    private struct Asset: Decodable {
        let name: String
        let state: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name, state
            case browserDownloadURL = "browser_download_url"
        }
    }

    static let releasesPage = URL(string: "https://github.com/wybaby168/UniCodex/releases")!
    static let latestEndpoint = URL(string: "https://api.github.com/repos/wybaby168/UniCodex/releases/latest")!
    static let architecture: String = {
        #if arch(arm64)
            "arm64"
        #else
            "x86_64"
        #endif
    }()

    let version: ReleaseVersion
    let pageURL: URL
    let downloadURL: URL?

    static func latest() async throws -> Self? {
        var request = URLRequest(url: latestEndpoint, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 20
        let session = URLSession(configuration: config)
        defer { session.finishTasksAndInvalidate() }
        let (data, response) = try await session.data(for: request)
        return try read(data, response: response)
    }

    static func read(_ data: Data, response: URLResponse, architecture: String = Self.architecture) throws -> Self? {
        guard let response = response as? HTTPURLResponse, response.url == latestEndpoint else {
            throw URLError(.badServerResponse)
        }
        if response.statusCode == 404 { return nil }
        guard response.statusCode == 200, data.count <= 1024 * 1024 else { throw URLError(.badServerResponse) }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        let tag = listing.tagName
        let value = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !listing.draft, !listing.prerelease, let version = ReleaseVersion(value), version.isStable else {
            throw URLError(.badServerResponse)
        }

        let page = releasesPage.appendingPathComponent("tag").appendingPathComponent(tag)
        let downloads = releasesPage.appendingPathComponent("download").appendingPathComponent(tag)
        for target in [architecture, "universal"] {
            for suffix in ["dmg", "zip"] {
                let name = "UniCodex-macos-\(target).\(suffix)"
                let url = downloads.appendingPathComponent(name)
                if listing.assets.contains(where: {
                    $0.name == name && $0.state == "uploaded" && $0.browserDownloadURL == url.absoluteString
                }) {
                    return Self(version: version, pageURL: page, downloadURL: url)
                }
            }
        }
        return Self(version: version, pageURL: page, downloadURL: nil)
    }
}

@Observable @MainActor
final class UniCodexAppUpdate {
    private enum Status {
        case ready, checking, noRelease, current
        case available(UniCodexRelease)
        case failed
    }

    let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String)
        .flatMap(ReleaseVersion.init)
    private var status = Status.ready

    var working: Bool {
        if case .checking = status { return true }
        return false
    }

    var release: UniCodexRelease? {
        if case .available(let release) = status { return release }
        return nil
    }

    func message(using strings: UIStrings) -> String {
        switch status {
        case .ready: return strings.text("app_update.ready")
        case .checking: return strings.text("app_update.checking")
        case .noRelease: return strings.text("app_update.no_release")
        case .current: return strings.text("app_update.current")
        case .available(let release):
            let key = release.downloadURL == nil ? "app_update.no_installer" : "app_update.available"
            return strings.text(key, release.version.description)
        case .failed: return strings.text("app_update.failed")
        }
    }

    func check() async {
        guard !working else { return }
        let previous = status
        status = .checking
        do {
            guard let version else {
                status = .failed
                return
            }
            let latest = try await UniCodexRelease.latest()
            try Task.checkCancellation()
            if let latest {
                status = latest.version > version ? .available(latest) : .current
            } else {
                status = .noRelease
            }
        } catch {
            status = Task.isCancelled ? previous : .failed
        }
    }
}
