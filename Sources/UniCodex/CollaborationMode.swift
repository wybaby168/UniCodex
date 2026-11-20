import Foundation

struct CollaborationMode: Identifiable, Equatable {
    static let standard = Self(id: "default", name: "Default")

    let id: String
    let name: String

    var isPlan: Bool { id == "plan" }

    var symbol: String {
        switch id {
        case "plan": "list.bullet.clipboard"
        case Self.standard.id: "hammer"
        default: "slider.horizontal.3"
        }
    }

    func title(using strings: UIStrings) -> String {
        switch id {
        case "plan": strings.text("mode.plan")
        case Self.standard.id: strings.text("mode.default")
        default: name
        }
    }

    func settings(model: String, effort: String?) -> RPCObject {
        [
            "mode": id,
            "settings": [
                "model": model,
                "reasoning_effort": effort.map { $0 as Any } ?? NSNull(),
                "developer_instructions": NSNull(),
            ] as RPCObject,
        ]
    }

    static func advertised(in response: RPCObject?) -> [Self] {
        var seen = Set<String>()
        let modes = (response?["data"] as? [RPCObject] ?? []).compactMap { row -> Self? in
            guard let id = row["mode"] as? String, !id.isEmpty,
                let name = row["name"] as? String, !name.isEmpty, seen.insert(id).inserted
            else { return nil }
            return Self(id: id, name: name)
        }
        return modes.filter { $0.id == standard.id } + modes.filter { $0.id != standard.id }
    }
}

struct UserInputRequest: Identifiable {
    struct Question: Decodable, Identifiable {
        struct Option: Decodable, Identifiable {
            let label: String
            let description: String
            var id: String { label }
        }

        let id: String
        let header: String
        let question: String
        let isOther: Bool
        let isSecret: Bool
        let options: [Option]?
        var choices: [Option] { options ?? [] }
    }

    let wireID: Any
    let turnID: String
    let questions: [Question]
    var id: String { Approval.key(for: wireID) }

    init?(wireID: Any, params: RPCObject) {
        guard let turnID = params["turnId"] as? String,
            let rows = params["questions"] as? [RPCObject],
            let data = try? JSONSerialization.data(withJSONObject: rows),
            let questions = try? JSONDecoder().decode([Question].self, from: data), !questions.isEmpty,
            Set(questions.map(\.id)).count == questions.count
        else { return nil }
        self.wireID = wireID
        self.turnID = turnID
        self.questions = questions
    }

    func response(to answers: [String: String]) -> RPCObject? {
        guard answers.count == questions.count else { return nil }
        var values: [String: RPCObject] = [:]
        for question in questions {
            guard let answer = answers[question.id], !answer.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                question.choices.isEmpty || question.isOther || question.choices.contains(where: { $0.label == answer })
            else { return nil }
            values[question.id] = ["answers": [answer]]
        }
        return ["answers": values]
    }
}
