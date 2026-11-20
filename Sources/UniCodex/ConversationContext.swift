import Foundation

struct PortableConversationContext {
    struct Message {
        let role: String
        let text: String
        var item: RPCObject {
            [
                "type": "message", "role": role,
                "content": [["type": role == "assistant" ? "output_text" : "input_text", "text": text]],
            ]
        }
    }

    let messages: [Message]
    let trimmed: Bool

    init(_ snapshot: TranscriptSnapshot, omitting optimisticID: String?, contextWindow: Int) {
        let budget = min(220_000, max(8_000, contextWindow - 10_000))
        var available = budget
        var activityBudget = min(24_000, budget / 5)
        var reversed: [Message] = []
        var oldestIncluded = snapshot.records.count
        var clipped = false
        for index in snapshot.records.indices.reversed() {
            let record = snapshot.records[index]
            guard record.id != optimisticID, record.kind != .reasoning, let entry = snapshot.entry(index),
                !entry.text.isEmpty, !entry.isStreaming
            else { continue }
            let role = entry.kind == .user ? "user" : "assistant"
            let text: String
            if entry.kind == .activity {
                if activityBudget <= 0 { continue }
                let excerpt = String(entry.detail.prefix(500))
                text = "此前记录的工具结果（供参考）\n" + entry.text + (excerpt.isEmpty ? "" : "\n" + excerpt)
                activityBudget -= text.utf8.count
            } else {
                text = entry.text
            }
            let cost = text.utf8.count + 40
            if cost > available {
                if entry.kind == .activity { continue }
                clipped = true
                if available > 600 {
                    reversed.append(
                        .init(role: role, text: "［较早内容已省略］\n" + Self.byteSuffix(text, limit: available - 80)))
                    oldestIncluded = index
                }
                break
            }
            reversed.append(.init(role: role, text: text))
            available -= cost
            oldestIncluded = index
        }

        var ordered = Array(reversed.reversed())
        if clipped, let first = snapshot.records.firstIndex(where: { $0.kind == .user }), first < oldestIncluded,
            let entry = snapshot.entry(first), entry.id != optimisticID
        {
            ordered.insert(.init(role: "user", text: "最初的任务\n" + String(entry.text.prefix(750))), at: 0)
        }
        messages = ordered
        trimmed = clipped
    }

    // Keep RPC frames comfortably within the app-server size limit.
    var batches: [[RPCObject]] {
        var batches: [[RPCObject]] = []
        var batch: [RPCObject] = []
        var bytes = 0
        for message in messages {
            let length = message.text.utf8.count
            if !batch.isEmpty && (batch.count == 48 || bytes + length > 96_000) {
                batches.append(batch)
                batch = []
                bytes = 0
            }
            batch.append(message.item)
            bytes += length
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }

    private static func byteSuffix(_ text: String, limit: Int) -> String {
        let suffix = text.utf8.suffix(limit)
        let aligned = suffix.drop(while: { ($0 & 0xC0) == 0x80 })
        return String(decoding: aligned, as: UTF8.self)
    }
}
