import CryptoKit
import Foundation

struct CodexEngineRelease {
    private enum Channel: CaseIterable {
        case cdn, github

        var latest: URL {
            switch self {
            case .cdn: Self.openAI.appendingPathComponent("channels/latest")
            case .github: URL(string: "https://api.github.com/repos/openai/codex/releases/latest")!
            }
        }

        func asset(version: ReleaseVersion) -> URL {
            let root =
                switch self {
                case .cdn: Self.openAI.appendingPathComponent("releases").appendingPathComponent(version.description)
                case .github: Self.githubDownloads.appendingPathComponent("rust-v" + version.description)
                }
            return root.appendingPathComponent(CodexEngineRelease.programName + ".tar.gz")
        }

        private static let openAI = URL(string: "https://releases.openai.com/codex")!
        private static let githubDownloads = URL(string: "https://github.com/openai/codex/releases/download")!
    }

    private struct Listing: Decodable {
        struct Asset: Decodable {
            let name: String
            let digest: String?
            let browserDownloadURL: String

            enum CodingKeys: String, CodingKey {
                case name, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case assets
        }
    }

    private struct NPMPackage: Decodable {
        struct Distribution: Decodable {
            let tarball: URL
            let integrity: String
        }
        let name: String
        let version: String
        let os: [String]
        let cpu: [String]
        let dist: Distribution
    }

    private enum Package {
        case standalone(sha256: String)
        case npm(sha512: Data)

        func executable(in entries: [String]) -> String? {
            switch self {
            case .standalone:
                guard entries.count == 1, let entry = entries.first,
                    entry == programName || entry == "./" + programName
                else { return nil }
                return entry
            case .npm:
                let prefix = "package/vendor/" + platform.target + "/"
                let matches = entries.filter { $0 == prefix + "bin/codex" || $0 == prefix + "codex/codex" }
                return matches.count == 1 ? matches.first : nil
            }
        }

        func verifies(_ archive: URL) throws -> Bool {
            switch self {
            case .standalone(let sha256): return try CodexEngineFiles.digest(archive) == sha256
            case .npm(let sha512): return try Data(CodexEngineFiles.digest(archive, using: SHA512.self)) == sha512
            }
        }
    }

    private enum Failure: LocalizedError {
        case releasesUnavailable, downloadsUnavailable, invalidPackage

        var errorDescription: String? {
            let key =
                switch self {
                case .releasesUnavailable: "engine.status_no_release_source"
                case .downloadsUnavailable: "engine.status_no_download_source"
                case .invalidPackage: "engine.status_invalid_download"
                }
            return UIStrings.current.text(key)
        }
    }

    private static let npmManifest = URL(string: "https://registry.npmjs.org/@openai%2Fcodex")!
    private static let npmTarballs = URL(string: "https://registry.npmjs.org/@openai/codex/-")!
    private static let platform: (target: String, npmCPU: String) = {
        #if arch(arm64)
            ("aarch64-apple-darwin", "arm64")
        #else
            ("x86_64-apple-darwin", "x64")
        #endif
    }()
    private static var programName: String { "codex-" + platform.target }

    let version: ReleaseVersion
    private let archive: (sources: [URL], package: Package)?

    static func latest(using session: URLSession) async throws -> Self {
        for channel in Channel.allCases {
            do {
                let listing: Listing = try await manifest(channel.latest, using: session)
                return try read(listing, from: channel)
            } catch {
                try Task.checkCancellation()
            }
        }
        struct Latest: Decodable {
            let name: String
            let version: String
        }
        do {
            let latest: Latest = try await manifest(npmManifest.appendingPathComponent("latest"), using: session)
            if latest.name == "@openai/codex", let version = ReleaseVersion(latest.version), version.isStable {
                return Self(version: version, archive: nil)
            }
        } catch {
            try Task.checkCancellation()
        }
        throw Failure.releasesUnavailable
    }

    private static func read(_ listing: Listing, from channel: Channel) throws -> Self {
        let filename = programName + ".tar.gz"
        guard listing.tagName.hasPrefix("rust-v"),
            let version = ReleaseVersion(String(listing.tagName.dropFirst(6))),
            version.isStable, let asset = listing.assets.first(where: { $0.name == filename }),
            asset.browserDownloadURL == channel.asset(version: version).absoluteString,
            let digest = asset.digest, digest.range(of: #"^sha256:[a-f0-9]{64}$"#, options: .regularExpression) != nil
        else { throw Failure.releasesUnavailable }

        let alternate: Channel = channel == .cdn ? .github : .cdn
        let sources = [channel, alternate].map { $0.asset(version: version) }
        return Self(version: version, archive: (sources, .standalone(sha256: String(digest.dropFirst(7)))))
    }

    private static func manifest<T: Decodable>(_ url: URL, using session: URLSession) async throws -> T {
        var request = URLRequest(url: url, timeoutInterval: 10)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard response.url == url, (response as? HTTPURLResponse)?.statusCode == 200, data.count <= 2 * 1024 * 1024
        else { throw Failure.releasesUnavailable }
        return try JSONDecoder().decode(T.self, from: data)
    }

    func download(into scratch: URL, using session: URLSession) async throws -> URL {
        var invalidPackage = false
        if let archive {
            for source in archive.sources {
                do {
                    return try await download(source, package: archive.package, into: scratch, using: session)
                } catch {
                    try Task.checkCancellation()
                    if case Failure.invalidPackage = error { invalidPackage = true }
                }
            }
        }
        do {
            let (url, package) = try await npmPackage(using: session)
            return try await download(url, package: package, into: scratch, using: session)
        } catch {
            try Task.checkCancellation()
            if case Failure.invalidPackage = error { invalidPackage = true }
            throw invalidPackage ? Failure.invalidPackage : Failure.downloadsUnavailable
        }
    }

    private func npmPackage(using session: URLSession) async throws -> (URL, Package) {
        let cpu = Self.platform.npmCPU
        let build = version.description + "-darwin-" + cpu
        let url = Self.npmTarballs.appendingPathComponent("codex-" + build + ".tgz")
        let package: NPMPackage = try await Self.manifest(
            Self.npmManifest.appendingPathComponent(build), using: session)
        guard package.name == "@openai/codex", package.version == build,
            package.os == ["darwin"], package.cpu == [cpu], package.dist.tarball == url,
            package.dist.integrity.hasPrefix("sha512-"),
            let digest = Data(base64Encoded: String(package.dist.integrity.dropFirst(7))),
            digest.count == SHA512.byteCount
        else { throw Failure.invalidPackage }
        return (url, .npm(sha512: digest))
    }

    private func download(_ url: URL, package: Package, into scratch: URL, using session: URLSession) async throws
        -> URL
    {
        let (downloaded, response) = try await session.download(from: url)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.downloadsUnavailable }

        let program = scratch.appendingPathComponent("codex")
        do {
            try await Task.detached(priority: .utility) {
                let size = try downloaded.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                guard (1...300 * 1024 * 1024).contains(size), try package.verifies(downloaded) else {
                    throw Failure.invalidPackage
                }
                let entries = try CodexEngineFiles.run("/usr/bin/tar", ["-tzf", downloaded.path], timeout: 60)
                    .split(whereSeparator: \.isNewline).map(String.init)
                guard let entry = package.executable(in: entries) else { throw Failure.invalidPackage }
                _ = try CodexEngineFiles.run(
                    "/usr/bin/tar", ["-xOzf", downloaded.path, entry], outputFile: program, timeout: 60)
                try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: program.path)
                _ = try CodexEngineFiles.run("/usr/bin/codesign", ["--verify", "--strict", program.path])
                guard try CodexEngineFiles.version(of: program) == version else { throw Failure.invalidPackage }
            }.value
        } catch {
            try? FileManager.default.removeItem(at: program)
            throw Failure.invalidPackage
        }
        return program
    }

    private final class OfficialDownloads: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            guard let source = task.originalRequest?.url?.host,
                let url = request.url, url.scheme == "https", url.user == nil, url.password == nil
            else { return completionHandler(nil) }
            let githubAsset = source == "github.com" && url.host == "release-assets.githubusercontent.com"
            completionHandler(url.host == source || githubAsset ? request : nil)
        }
    }

    static let session: URLSession = makeSession()

    static func makeSession(protocols: [AnyClass] = []) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 18
        config.timeoutIntervalForResource = 600
        config.protocolClasses = protocols
        return URLSession(configuration: config, delegate: OfficialDownloads(), delegateQueue: nil)
    }
}
