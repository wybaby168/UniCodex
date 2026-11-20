import Foundation

enum SessionPermissionMode: String, CaseIterable, Identifiable {
    case readOnly
    case workspace
    case alwaysApprove

    var id: Self { self }
    var title: String {
        switch self {
        case .readOnly: UIStrings.current.text("permission.read")
        case .workspace: UIStrings.current.text("permission.workspace")
        case .alwaysApprove: UIStrings.current.text("permission.always")
        }
    }
    var description: String {
        switch self {
        case .readOnly: UIStrings.current.text("permission.read_help")
        case .workspace: UIStrings.current.text("permission.workspace_help")
        case .alwaysApprove: UIStrings.current.text("permission.full_help")
        }
    }
    var symbol: String {
        switch self {
        case .readOnly: "lock"
        case .workspace: "shield"
        case .alwaysApprove: "lock.open"
        }
    }
    var sandbox: String {
        switch self {
        case .readOnly: "read-only"
        case .workspace: "workspace-write"
        case .alwaysApprove: "danger-full-access"
        }
    }
    var approvalPolicy: String { self == .alwaysApprove ? "never" : "on-request" }
    var sandboxPolicy: RPCObject {
        switch self {
        case .readOnly:
            ["type": "readOnly", "networkAccess": false]
        case .workspace:
            [
                "type": "workspaceWrite", "writableRoots": [String](), "networkAccess": false,
                "excludeTmpdirEnvVar": false, "excludeSlashTmp": false,
            ]
        case .alwaysApprove:
            ["type": "dangerFullAccess"]
        }
    }

    func allowed(by requirements: RPCObject) -> Bool {
        let sandboxes = requirements["allowedSandboxModes"] as? [String]
        let policies = requirements["allowedApprovalPolicies"] as? [Any]
        return (sandboxes?.contains(sandbox) ?? true)
            && (policies?.contains { $0 as? String == approvalPolicy } ?? true)
    }
}

struct ApprovalOption: Identifiable {
    enum Scope: String { case decline, once, session, rule }
    let scope: Scope
    let title: String
    let result: RPCObject
    var ruleDescription: String? = nil

    var id: Scope { scope }

    static func decision(_ scope: Scope, _ title: String, _ decision: Any) -> Self {
        .init(scope: scope, title: title, result: ["decision": decision])
    }
}

struct Approval: Identifiable {
    let wireID: Any
    let turnID: String
    let title: String
    let reason: String
    let detail: String
    let options: [ApprovalOption]

    var id: String { Self.key(for: wireID) }

    static func key(for wireID: Any) -> String {
        let type = wireID is String ? "string" : "number"
        return "\(type):\(wireID)"
    }

    init?(wireID: Any, method: String, params: RPCObject, itemDetail: String?) {
        guard let turn = params["turnId"] as? String else { return nil }
        self.wireID = wireID
        turnID = turn
        reason = redact(params["reason"] as? String ?? "")
        let folder = params["cwd"] as? String
        let parts: [String?]
        switch method {
        case "item/commandExecution/requestApproval":
            let network = params["networkApprovalContext"] as? RPCObject
            let host = network?["host"] as? String
            let kind = params["kind"] as? String ?? "command"
            title = host != nil ? "approval.network" : kind == "writeStdin" ? "approval.input" : "approval.run"
            let endpoint = [host, network?["protocol"] as? String].compactMap { $0 }.joined(separator: " · ")
            parts = [
                host != nil ? endpoint : params["command"] as? String ?? itemDetail, folder,
                Self.describe(params["additionalPermissions"] as? RPCObject),
            ]
            options = Self.commandOptions(params, standardCommand: kind == "command", managedNetwork: host != nil)
        case "item/fileChange/requestApproval":
            title = "approval.files"
            parts = [params["grantRoot"] as? String, itemDetail]
            options = [
                .decision(.decline, "approval.deny", "decline"),
                .decision(.once, "approval.once", "accept"),
                .decision(.session, "approval.for_session", "acceptForSession"),
            ]
        case "item/permissions/requestApproval":
            guard let permissions = params["permissions"] as? RPCObject else { return nil }
            let requested = permissions.filter { !($0.value is NSNull) }
            title = "approval.add_permissions"
            parts = [Self.describe(requested), folder]
            options = [
                .init(scope: .decline, title: "approval.deny", result: ["permissions": RPCObject(), "scope": "turn"]),
                .init(scope: .once, title: "approval.one_turn", result: ["permissions": requested, "scope": "turn"]),
                .init(
                    scope: .session, title: "approval.for_session",
                    result: ["permissions": requested, "scope": "session"]),
            ]
        default:
            return nil
        }
        detail = TranscriptEntry.boundedLog(parts.compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n\n"))
    }

    private static func commandOptions(_ params: RPCObject, standardCommand: Bool, managedNetwork: Bool)
        -> [ApprovalOption]
    {
        let available = params["availableDecisions"] as? [Any]
        let names = available?.compactMap { $0 as? String }
        var choices: [ApprovalOption] = []
        if names?.contains("decline") != false {
            choices.append(.decision(.decline, "approval.deny", "decline"))
        } else if names?.contains("cancel") == true {
            choices.append(.decision(.decline, "common.cancel", "cancel"))
        }
        if names?.contains("accept") != false {
            choices.append(.decision(.once, "approval.once", "accept"))
        }
        if standardCommand && (names?.contains("acceptForSession") ?? true) {
            choices.append(.decision(.session, "approval.for_session", "acceptForSession"))
        }
        if standardCommand, let rule = ruleOption(params, offered: available, managedNetwork: managedNetwork) {
            choices.append(rule)
        }
        return choices
    }

    private static func ruleOption(_ params: RPCObject, offered: [Any]?, managedNetwork: Bool) -> ApprovalOption? {
        let decisions = offered?.compactMap { $0 as? RPCObject }
        if managedNetwork {
            let key = "applyNetworkPolicyAmendment"
            let options =
                decisions?.compactMap { ($0[key] as? RPCObject)?["network_policy_amendment"] as? RPCObject }
                ?? params["proposedNetworkPolicyAmendments"] as? [RPCObject] ?? []
            guard let rule = options.first(where: { $0["action"] as? String == "allow" }),
                let host = rule["host"] as? String, !host.isEmpty
            else { return nil }
            return ApprovalOption(
                scope: .rule, title: "approval.network_rule",
                result: ["decision": [key: ["network_policy_amendment": rule]]],
                ruleDescription: redact(host))
        }
        let key = "acceptWithExecpolicyAmendment"
        let prefix =
            decisions?.compactMap { ($0[key] as? RPCObject)?["execpolicy_amendment"] as? [String] }.first
            ?? (offered == nil ? params["proposedExecpolicyAmendment"] as? [String] : nil)
        guard let prefix, !prefix.isEmpty, prefix.allSatisfy({ !$0.isEmpty }) else { return nil }
        let display = prefix.map { String(reflecting: $0) }.joined(separator: " ")
        return ApprovalOption(
            scope: .rule, title: "approval.command_rule",
            result: ["decision": [key: ["execpolicy_amendment": prefix]]],
            ruleDescription: redact(display))
    }

    private static func describe(_ fields: RPCObject?) -> String? {
        guard let fields, !fields.isEmpty,
            let data = try? JSONSerialization.data(
                withJSONObject: fields,
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else {
            return nil
        }
        return String(decoding: data, as: UTF8.self)
    }
}
