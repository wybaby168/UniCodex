import CryptoKit
import Foundation

struct GeminiFunction {
    let name: String
    let namespace: String?
    let custom: Bool

    var wireName: String {
        if namespace == nil, name.range(of: #"^[A-Za-z_][A-Za-z0-9_.-]{0,63}$"#, options: .regularExpression) != nil {
            return name
        }
        let digest = SHA256.hash(data: Data(((namespace ?? "") + "/" + name).utf8))
        let hash = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        let label = name.replacingOccurrences(of: #"[^A-Za-z0-9_]"#, with: "_", options: .regularExpression)
        return "fn_" + hash + "_" + label.prefix(40)
    }
}

/// Codex persists call IDs in its transcript, including across engine restarts.
/// Keep Google's opaque call metadata with the ID so continuation can replay it.
struct GeminiCall: Codable {
    let providerID: String?
    let signature: String?

    func encodedID() -> String {
        let id = "call_gemini_" + UUID().uuidString.lowercased()
        guard providerID != nil || signature != nil, let data = try? JSONEncoder().encode(self) else { return id }
        return id + "." + data.base64EncodedString()
    }

    static func decode(_ id: String) -> Self? {
        guard id.hasPrefix("call_gemini_"), let suffix = id.split(separator: ".", maxSplits: 1).dropFirst().first,
            let bytes = Data(base64Encoded: String(suffix))
        else { return nil }
        return try? JSONDecoder().decode(Self.self, from: bytes)
    }
}

struct GeminiRequest {
    let model: ProviderModel
    let payload: RPCObject
    let functions: [String: GeminiFunction]

    init(_ request: RPCObject, model: ProviderModel) throws {
        self.model = model
        let input = request["input"] as? [RPCObject] ?? []
        var conversation = Conversation()
        if let instructions = request["instructions"] as? String, !instructions.isEmpty {
            conversation.instructions.append(instructions)
        }
        if let text = request["input"] as? String { conversation.append([["text": text]], role: "user") }
        for item in input { try conversation.add(item) }
        conversation.flushResults()
        guard !conversation.contents.isEmpty else { throw WorkbenchError("Gemini 需要至少一条会话消息。") }

        let additional = input.filter { $0["type"] as? String == "additional_tools" }
            .flatMap { $0["tools"] as? [RPCObject] ?? [] }
        let definitions = (request["tools"] as? [RPCObject] ?? []) + additional
        var functions: [String: GeminiFunction] = [:]
        var declarations: [RPCObject] = []
        for tool in definitions {
            let namespace = tool["type"] as? String == "namespace" ? tool["name"] as? String : nil
            for entry in (namespace == nil ? [tool] : (tool["tools"] as? [RPCObject] ?? [])) {
                let type = entry["type"] as? String ?? "function"
                guard type == "function" || type == "custom", let name = entry["name"] as? String else { continue }
                let function = GeminiFunction(name: name, namespace: namespace, custom: type == "custom")
                let wireName = function.wireName
                guard functions[wireName] == nil else { continue }
                functions[wireName] = function
                let description = entry["description"] as? String ?? name
                var declaration: RPCObject = ["name": wireName, "description": description]
                if function.custom {
                    let grammar = (entry["format"] as? RPCObject)?["definition"] as? String
                    declaration["parametersJsonSchema"] =
                        [
                            "type": "object",
                            "properties": ["input": ["type": "string", "description": grammar ?? description]],
                            "required": ["input"],
                        ] as RPCObject
                } else if var schema = entry["parameters"] as? RPCObject {
                    schema.removeValue(forKey: "$schema")
                    declaration["parametersJsonSchema"] = schema
                }
                declarations.append(declaration)
            }
        }
        self.functions = functions

        let reasoning = request["reasoning"] as? RPCObject
        let effort = reasoning?["effort"] as? String ?? model.defaultEffort
        let level = model.efforts.contains(effort) ? effort : model.defaultEffort
        var generation: RPCObject = [
            "thinkingConfig": ["thinkingLevel": level, "includeThoughts": reasoning?["summary"] as? String != "none"]
        ]
        if let limit = request["max_output_tokens"] as? Int, limit > 0 { generation["maxOutputTokens"] = limit }
        var payload: RPCObject = ["contents": conversation.contents, "generationConfig": generation]
        if !conversation.instructions.isEmpty {
            payload["systemInstruction"] = ["parts": [["text": conversation.instructions.joined(separator: "\n\n")]]]
        }
        if !declarations.isEmpty {
            payload["tools"] = [["functionDeclarations": declarations]]
            var config: RPCObject = ["mode": "AUTO"]
            switch request["tool_choice"] as? String {
            case "none": config["mode"] = "NONE"
            case "required": config["mode"] = "ANY"
            default:
                if let chosen = request["tool_choice"] as? RPCObject, let name = chosen["name"] as? String,
                    let function = functions.values.first(where: {
                        $0.name == name && $0.namespace == chosen["namespace"] as? String
                    })
                {
                    config = ["mode": "ANY", "allowedFunctionNames": [function.wireName]]
                }
            }
            payload["toolConfig"] = ["functionCallingConfig": config]
        }
        self.payload = payload
    }

    private struct Conversation {
        var contents: [RPCObject] = []
        var instructions: [String] = []
        private var precedingWasToolResult = false
        private var calls: [String: (name: String, order: Int)] = [:]
        private var results: [(order: Int, part: RPCObject)] = []

        mutating func append(_ parts: [RPCObject], role: String, toolResult: Bool = false) {
            guard !parts.isEmpty else { return }
            if let last = contents.indices.last, contents[last]["role"] as? String == role,
                toolResult == precedingWasToolResult
            {
                contents[last]["parts"] = (contents[last]["parts"] as? [RPCObject] ?? []) + parts
            } else {
                contents.append(["role": role, "parts": parts])
            }
            precedingWasToolResult = toolResult
        }

        mutating func flushResults() {
            guard !results.isEmpty else { return }
            append(results.sorted(by: { $0.order < $1.order }).map(\.part), role: "user", toolResult: true)
            results.removeAll(keepingCapacity: true)
        }

        mutating func add(_ item: RPCObject) throws {
            switch item["type"] as? String {
            case "function_call_output", "custom_tool_call_output":
                let output = item["output"] ?? ""
                if let id = item["call_id"] as? String, let call = calls[id] {
                    var result: RPCObject = ["name": call.name, "response": ["output": output]]
                    result["id"] = GeminiCall.decode(id)?.providerID
                    results.append((call.order, ["functionResponse": result]))
                } else {
                    flushResults()
                    append([["text": "Previous tool output:\n" + Self.text(for: output)]], role: "user")
                }
            case "function_call", "custom_tool_call":
                flushResults()
                guard let id = item["call_id"] as? String, let name = item["name"] as? String else { return }
                let custom = item["type"] as? String == "custom_tool_call"
                let function = GeminiFunction(name: name, namespace: item["namespace"] as? String, custom: custom)
                let meta = GeminiCall.decode(id)
                let args: RPCObject
                if custom {
                    args = ["input": item["input"] as? String ?? ""]
                } else if let json = item["arguments"] as? String, !json.isEmpty {
                    guard let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? RPCObject else {
                        throw WorkbenchError("对话中的工具参数格式有误。")
                    }
                    args = parsed
                } else {
                    args = [:]
                }
                var call: RPCObject = ["name": function.wireName, "args": args]
                call["id"] = meta?.providerID
                var part: RPCObject = ["functionCall": call]
                part["thoughtSignature"] = meta?.signature
                calls[id] = (function.wireName, calls.count)
                append([part], role: "model")
            case "message":
                flushResults()
                let role = item["role"] as? String ?? "user"
                let parts = (item["content"] as? [RPCObject] ?? []).compactMap(Self.part)
                if role == "system" || role == "developer" {
                    instructions.append(contentsOf: parts.compactMap { $0["text"] as? String })
                } else {
                    append(parts, role: role == "assistant" ? "model" : "user")
                }
            case "reasoning":
                guard let value = item["encrypted_content"] as? String,
                    value.hasPrefix(GeminiResponse.textSignaturePrefix),
                    let last = contents.indices.last, contents[last]["role"] as? String == "model",
                    var parts = contents[last]["parts"] as? [RPCObject], let index = parts.indices.last,
                    parts[index]["text"] != nil
                else { return }
                parts[index]["thoughtSignature"] = String(value.dropFirst(GeminiResponse.textSignaturePrefix.count))
                contents[last]["parts"] = parts
            default:
                break
            }
        }

        private static func part(_ item: RPCObject) -> RPCObject? {
            if let text = item["text"] as? String, !text.isEmpty { return ["text": text] }
            guard let image = item["image_url"] as? String, image.hasPrefix("data:image/"),
                let separator = image.range(of: ";base64,")
            else { return nil }
            return [
                "inlineData": [
                    "mimeType": String(image[image.index(image.startIndex, offsetBy: 5)..<separator.lowerBound]),
                    "data": String(image[separator.upperBound...]),
                ]
            ]
        }

        private static func text(for value: Any) -> String {
            if let text = value as? String { return text }
            guard let data = try? JSONSerialization.data(withJSONObject: value, options: .fragmentsAllowed) else {
                return ""
            }
            return String(decoding: data, as: UTF8.self)
        }
    }
}
