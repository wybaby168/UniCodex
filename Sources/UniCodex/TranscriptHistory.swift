import Foundation

struct TranscriptArchive: Sendable {
    let index: TranscriptIndex
    let recent: [TranscriptEntry]
}

@MainActor
struct TranscriptArchiveBuilder {
    private var index = TranscriptIndex()
    private var recent: [TranscriptEntry] = []

    mutating func append(_ entries: [TranscriptEntry], namespace: String?) throws {
        for var entry in entries {
            if let namespace { entry.id = namespace + "/" + entry.id }
            guard index.positions[entry.id] == nil else { continue }
            try index.store(entry)
            recent.append(entry)
        }
        if recent.count > WorkbenchSession.recentEntryLimit {
            recent.removeFirst(recent.count - WorkbenchSession.recentEntryLimit)
        }
        var bytes = recent.reduce(0) { $0 + $1.estimatedBytes }
        while recent.count > 1 && bytes > WorkbenchSession.recentEstimatedByteLimit {
            bytes -= recent.removeFirst().estimatedBytes
        }
    }

    func finish(in folder: URL) async -> TranscriptArchive {
        let retained = recent
        let prepared = await Task.detached(priority: .userInitiated) {
            retained.map { $0.preparingDocument(in: folder) }
        }.value
        return .init(index: index, recent: prepared)
    }
}

@MainActor
enum TranscriptHistoryReader {
    private struct Page {
        let items: [TranscriptEntry]
        let next: String?
    }

    static func read(
        _ rpc: CodexConnection, threadID: String, namespace: String?,
        into archive: inout TranscriptArchiveBuilder
    ) async throws {
        var cursor: String?
        var cursors = Set<String>()
        var paginatesItems = true

        repeat {
            try Task.checkCancellation()
            var params: RPCObject = ["threadId": threadID, "sortDirection": "asc"]
            if let cursor { params["cursor"] = cursor }
            let page: Page
            if paginatesItems {
                do {
                    page = try await readPage(rpc, params: params, paginatesItems: true)
                } catch let error as EngineRequestError where cursor == nil && itemPaginationUnavailable(error) {
                    paginatesItems = false
                    page = try await readPage(rpc, params: params, paginatesItems: false)
                }
            } else {
                page = try await readPage(rpc, params: params, paginatesItems: false)
            }

            try archive.append(page.items, namespace: namespace)
            cursor = page.next
            if let cursor, !cursors.insert(cursor).inserted {
                throw WorkbenchError("会话历史的分页游标重复。")
            }
        } while cursor != nil
    }

    private static func readPage(
        _ rpc: CodexConnection, params base: RPCObject,
        paginatesItems: Bool
    ) async throws -> Page {
        var params = base
        if paginatesItems {
            params["limit"] = 48
            let reply = try await rpc.request("thread/items/list", params)
            let raw = (reply["data"] as? [RPCObject] ?? []).compactMap { $0["item"] as? RPCObject }
            return .init(items: displayItems(raw), next: reply["nextCursor"] as? String)
        }
        params["limit"] = 1
        params["itemsView"] = "full"
        let reply = try await rpc.request("thread/turns/list", params)
        let turn = (reply["data"] as? [RPCObject] ?? []).first
        return .init(items: displayItems(turn?["items"] as? [RPCObject] ?? []), next: reply["nextCursor"] as? String)
    }

    private static func itemPaginationUnavailable(_ error: EngineRequestError) -> Bool {
        let message = error.message.lowercased()
        return error.code == -32601 || message.contains("does not support") || message.contains("unsupported")
            || message.contains("requires paginated history")
    }

    private static func displayItems(_ items: [RPCObject]) -> [TranscriptEntry] {
        items.compactMap(TranscriptEntry.init).filter { !$0.text.isEmpty }
    }
}
