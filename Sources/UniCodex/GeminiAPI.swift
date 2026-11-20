import Foundation

enum GeminiAPI {
    static let baseURL = URL(string: "https://generativelanguage.googleapis.com/v1beta")!

    static func request(at url: URL, key: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        return request
    }

    static func session(timeout: TimeInterval) -> URLSession {
        let settings = URLSessionConfiguration.ephemeral
        settings.timeoutIntervalForRequest = timeout
        settings.timeoutIntervalForResource = max(timeout, 300)
        return URLSession(configuration: settings, delegate: DirectRequests(), delegateQueue: nil)
    }

    static func availableModelIDs(using key: String) async throws -> [String] {
        struct Page: Decodable {
            struct Model: Decodable {
                let name: String
                let supportedGenerationMethods: [String]?
            }
            let models: [Model]
            let nextPageToken: String?
        }

        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty, !token.contains(where: \.isWhitespace) else {
            throw WorkbenchError("请输入有效的 Google API Key。")
        }
        let client = session(timeout: 12)
        defer { client.invalidateAndCancel() }
        var ids = Set<String>()
        var nextPage: String?
        var seenPages = Set<String>()
        repeat {
            var url = URLComponents(url: baseURL.appendingPathComponent("models"), resolvingAgainstBaseURL: false)!
            url.queryItems = [.init(name: "pageSize", value: "1000")]
            if let nextPage { url.queryItems?.append(.init(name: "pageToken", value: nextPage)) }
            let (data, response) = try await client.data(for: request(at: url.url!, key: token))
            let status = (response as? HTTPURLResponse)?.statusCode ?? 502
            guard status == 200 else { throw WorkbenchError(message(for: status)) }
            let page = try JSONDecoder().decode(Page.self, from: data)
            for model in page.models where model.supportedGenerationMethods?.contains("generateContent") == true {
                if model.name.hasPrefix("models/") { ids.insert(String(model.name.dropFirst("models/".count))) }
            }
            nextPage = page.nextPageToken.flatMap { !$0.isEmpty && seenPages.insert($0).inserted ? $0 : nil }
        } while nextPage != nil

        let available = ProviderKind.gemini.builtInModels.map(\.id).filter(ids.contains)
        guard !available.isEmpty else { throw WorkbenchError("此 Google API Key 的目录没有工作台支持的 Gemini 模型。") }
        return available
    }

    static func message(for status: Int) -> String {
        switch status {
        case 400: "Google 拒绝了请求（400）。请检查模型、API Key 和地区设置。"
        case 401, 403: "Google API Key 验证失败或缺少权限（\(status)）。"
        case 404: "Google 未提供此模型（404）。请在顶部选择其他 Gemini 模型。"
        case 429: "Gemini 达到了请求频率或项目额度限制（429）。"
        default: "Gemini 请求失败（\(status)）。"
        }
    }

    private final class DirectRequests: NSObject, URLSessionTaskDelegate {
        func urlSession(
            _ session: URLSession, task: URLSessionTask,
            willPerformHTTPRedirection response: HTTPURLResponse,
            newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void
        ) {
            completionHandler(nil)
        }
    }
}
