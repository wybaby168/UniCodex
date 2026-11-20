import Foundation

struct GeminiResponse {
    static let textSignaturePrefix = "workbench_gemini_text:"

    private enum Part: Equatable { case message, summary }
    private struct TextItem {
        let kind: Part
        let id: String
        var text: String = ""
    }

    private let request: GeminiRequest
    private let responseID = "resp_" + UUID().uuidString.lowercased()
    private let createdAt = Int(Date().timeIntervalSince1970)
    private var items: [RPCObject] = []
    private var usage: RPCObject = [:]
    private var current: TextItem?
    private var finishReason: String?
    private var events = Data()
    private var sequence = 0

    init(_ request: GeminiRequest) { self.request = request }

    mutating func begin() throws -> Data {
        try emit("response.created", ["response": response(status: "in_progress")])
        return drain()
    }

    mutating func consume(_ chunk: RPCObject) throws -> Data {
        if let feedback = chunk["promptFeedback"] as? RPCObject, feedback["blockReason"] != nil {
            throw WorkbenchError("Google 拦截了此次 Gemini 请求。")
        }
        if let metadata = chunk["usageMetadata"] as? RPCObject { usage = metadata }
        guard let candidate = (chunk["candidates"] as? [RPCObject])?.first else { return Data() }
        finishReason = candidate["finishReason"] as? String ?? finishReason
        let content = candidate["content"] as? RPCObject
        for part in content?["parts"] as? [RPCObject] ?? [] {
            let signature = part["thoughtSignature"] as? String
            if let call = part["functionCall"] as? RPCObject {
                try endText()
                try functionCall(call, signature: signature)
            } else {
                let isSummary = part["thought"] as? Bool == true
                if let text = part["text"] as? String, !text.isEmpty {
                    try appendText(text, kind: isSummary ? .summary : .message)
                }
                if let signature, !isSummary {
                    try endText()
                    try completeItem([
                        "type": "reasoning", "id": itemID("rs"), "summary": [RPCObject](),
                        "encrypted_content": Self.textSignaturePrefix + signature,
                    ])
                }
            }
        }
        return drain()
    }

    mutating func finish() throws -> Data {
        try endText()
        switch finishReason {
        case "STOP":
            try emit("response.completed", ["response": response(status: "completed")])
        case "MAX_TOKENS":
            var incomplete = response(status: "incomplete")
            incomplete["incomplete_details"] = ["reason": "max_output_tokens"]
            try emit("response.incomplete", ["response": incomplete])
        case nil:
            throw WorkbenchError("Gemini 的回复流提前断开了。")
        default:
            throw WorkbenchError("Google 结束了此次 Gemini 回复（\(finishReason ?? "")）。")
        }
        return drain()
    }

    mutating func fail(_ error: String) -> Data {
        events.removeAll(keepingCapacity: true)
        try? emit("error", ["code": "gemini_stream_error", "message": error])
        return drain()
    }

    private mutating func functionCall(_ call: RPCObject, signature: String?) throws {
        guard let name = call["name"] as? String, let function = request.functions[name] else {
            throw WorkbenchError("Gemini 请求了当前任务中不可用的工具。")
        }
        let metadata = GeminiCall(providerID: call["id"] as? String, signature: signature)
        let args = call["args"] as? RPCObject ?? [:]
        var item: RPCObject = [
            "id": itemID("fc"), "name": function.name, "call_id": metadata.encodedID(),
            "type": function.custom ? "custom_tool_call" : "function_call", "status": "completed",
        ]
        item["namespace"] = function.namespace
        if function.custom {
            guard let input = args["input"] as? String else {
                throw WorkbenchError("Gemini 返回的工具调用缺少输入。")
            }
            item["input"] = input
        } else {
            let data = try JSONSerialization.data(withJSONObject: args, options: .sortedKeys)
            item["arguments"] = String(decoding: data, as: UTF8.self)
        }
        try completeItem(item)
    }

    private mutating func appendText(_ chunk: String, kind: Part) throws {
        if current?.kind != kind {
            try endText()
            let item = TextItem(kind: kind, id: itemID(kind == .message ? "msg" : "rs"))
            current = item
            if kind == .message {
                try emit(
                    "response.output_item.added", ["output_index": items.count, "item": message(item, done: false)])
                try emit(
                    "response.content_part.added",
                    [
                        "item_id": item.id, "output_index": items.count,
                        "content_index": 0, "part": textPart(""),
                    ])
            } else {
                try emit(
                    "response.output_item.added", ["output_index": items.count, "item": reasoning(item, done: false)])
                try emit(
                    "response.reasoning_summary_part.added",
                    [
                        "item_id": item.id, "output_index": items.count,
                        "summary_index": 0, "part": summaryPart(""),
                    ])
            }
        }
        guard let id = current?.id else { return }
        current?.text.append(chunk)
        if kind == .message {
            try emit(
                "response.output_text.delta",
                ["item_id": id, "output_index": items.count, "content_index": 0, "delta": chunk])
        } else {
            try emit(
                "response.reasoning_summary_text.delta",
                [
                    "item_id": id, "output_index": items.count,
                    "summary_index": 0, "delta": chunk,
                ])
        }
    }

    private mutating func endText() throws {
        guard let item = current else { return }
        current = nil
        let result: RPCObject
        if item.kind == .message {
            try emit(
                "response.output_text.done",
                [
                    "item_id": item.id, "output_index": items.count,
                    "content_index": 0, "text": item.text,
                ])
            try emit(
                "response.content_part.done",
                [
                    "item_id": item.id, "output_index": items.count,
                    "content_index": 0, "part": textPart(item.text),
                ])
            result = message(item, done: true)
        } else {
            try emit(
                "response.reasoning_summary_text.done",
                [
                    "item_id": item.id, "output_index": items.count,
                    "summary_index": 0, "text": item.text,
                ])
            result = reasoning(item, done: true)
        }
        try emit("response.output_item.done", ["output_index": items.count, "item": result])
        items.append(result)
    }

    private mutating func completeItem(_ item: RPCObject) throws {
        var begin = item
        if begin["status"] != nil { begin["status"] = "in_progress" }
        if begin["arguments"] != nil { begin["arguments"] = "" }
        if begin["input"] != nil { begin["input"] = "" }
        try emit("response.output_item.added", ["output_index": items.count, "item": begin])
        try emit("response.output_item.done", ["output_index": items.count, "item": item])
        items.append(item)
    }

    private func itemID(_ prefix: String) -> String { prefix + "_" + UUID().uuidString.lowercased() }

    private func message(_ item: TextItem, done: Bool) -> RPCObject {
        [
            "type": "message", "id": item.id, "role": "assistant",
            "status": done ? "completed" : "in_progress", "content": done ? [textPart(item.text)] : [],
        ]
    }

    private func reasoning(_ item: TextItem, done: Bool) -> RPCObject {
        ["type": "reasoning", "id": item.id, "summary": done ? [summaryPart(item.text)] : []]
    }

    private func textPart(_ text: String) -> RPCObject { ["type": "output_text", "text": text, "annotations": []] }
    private func summaryPart(_ text: String) -> RPCObject { ["type": "summary_text", "text": text] }

    private func response(status: String) -> RPCObject {
        var response: RPCObject = [
            "id": responseID, "object": "response", "status": status,
            "created_at": createdAt, "model": request.model.id, "output": items,
        ]
        if status != "in_progress" {
            let input = usage["promptTokenCount"] as? Int ?? 0
            let cached = usage["cachedContentTokenCount"] as? Int ?? 0
            let thinking = usage["thoughtsTokenCount"] as? Int ?? 0
            let output = (usage["candidatesTokenCount"] as? Int ?? 0) + thinking
            response["usage"] =
                [
                    "input_tokens": input, "output_tokens": output,
                    "total_tokens": usage["totalTokenCount"] as? Int ?? input + output,
                    "input_tokens_details": ["cached_tokens": cached],
                    "output_tokens_details": ["reasoning_tokens": thinking],
                ] as RPCObject
        }
        return response
    }

    private mutating func emit(_ name: String, _ fields: RPCObject) throws {
        var data = fields
        data["type"] = name
        data["sequence_number"] = sequence
        sequence += 1
        events.append(contentsOf: "event: \(name)\ndata: ".utf8)
        events.append(try JSONSerialization.data(withJSONObject: data))
        events.append(contentsOf: "\n\n".utf8)
    }

    private mutating func drain() -> Data {
        let buffered = events
        events = Data()
        return buffered
    }
}
