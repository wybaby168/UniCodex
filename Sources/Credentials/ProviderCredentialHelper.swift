import CryptoKit
import Darwin
import Foundation
import Security

// The helper's signed executable persists across app updates. The file-based
// keychain can then keep granting access to the same code-directory hash.
private func isTrustedParent() -> Bool {
    var parent: SecCode?
    let attributes = [kSecGuestAttributePid as String: getppid()] as CFDictionary
    guard SecCodeCopyGuestWithAttributes(nil, attributes, [], &parent) == errSecSuccess, let parent else { return false }
    var path: CFURL?
    var staticParent: SecStaticCode?
    guard SecCodeCopyStaticCode(parent, [], &staticParent) == errSecSuccess, let staticParent,
          SecCodeCopyPath(staticParent, [], &path) == errSecSuccess, let path,
          (path as URL).standardizedFileURL.path == "/Applications/UniCodex.app" else { return false }

    var code: SecCode?
    var binary: SecStaticCode?
    var signing: CFDictionary?
    guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
          SecCodeCopyStaticCode(code, [], &binary) == errSecSuccess, let binary,
          SecCodeCopySigningInformation(binary, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess,
          let metadata = signing as? [String: Any],
          let leaf = (metadata[kSecCodeInfoCertificates as String] as? [SecCertificate])?.first else { return false }
    let fingerprint = Insecure.SHA1.hash(data: SecCertificateCopyData(leaf) as Data)
        .map { String(format: "%02x", $0) }.joined()
    let text = "identifier \"local.codex-api-workbench\" and certificate leaf = H\"\(fingerprint)\""
    var requirement: SecRequirement?
    return SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess &&
        SecCodeCheckValidity(parent, [], requirement) == errSecSuccess
}

private func lookup(_ id: String, service: String) -> [String: Any] {
    [kSecClass as String: kSecClassGenericPassword,
     kSecAttrService as String: service, kSecAttrAccount as String: id]
}

private func read(_ lookup: [String: Any]) -> (OSStatus, Data?) {
    var request = lookup
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var value: CFTypeRef?
    let status = SecItemCopyMatching(request as CFDictionary, &value)
    return (status, value as? Data)
}

private func save(_ bytes: Data, to lookup: [String: Any]) -> OSStatus {
    let status = SecItemUpdate(lookup as CFDictionary, [kSecValueData as String: bytes] as CFDictionary)
    guard status == errSecItemNotFound else { return status }
    var item = lookup
    item[kSecValueData as String] = bytes
    item[kSecAttrLabel as String] = "UniCodex · \(lookup[kSecAttrAccount as String] ?? "")"
    return SecItemAdd(item as CFDictionary, nil)
}

private func finish(_ status: OSStatus) -> Never {
    switch status {
    case errSecSuccess: exit(0)
    case errSecItemNotFound: exit(3)
    case errSecInteractionNotAllowed, errSecAuthFailed, errSecUserCanceled: exit(4)
    default: exit(5)
    }
}

let args = CommandLine.arguments
guard args.count == 3, isTrustedParent(),
      args[2].range(of: #"^[A-Za-z0-9-]{1,80}$"#, options: .regularExpression) != nil else { exit(77) }
let id = args[2]
let current = lookup(id, service: "local.codex-api-workbench.provider.v2")
let legacy = lookup(id, service: "local.codex-api-workbench.provider")
// Authentication UI is scoped to this process and opened only from an explicit
// restore action, never from inference or the MCP path.
SecKeychainSetUserInteractionAllowed(args[1] == "restore")
switch args[1] {
case "read":
    let (status, bytes) = read(current)
    if status == errSecSuccess, let bytes { FileHandle.standardOutput.write(bytes) }
    finish(status)
case "write":
    guard let bytes = try? FileHandle.standardInput.readToEnd(), (8...8192).contains(bytes.count),
          let key = String(data: bytes, encoding: .utf8), !key.contains(where: \.isWhitespace) else { exit(64) }
    finish(save(bytes, to: current))
case "delete":
    let prior = SecItemDelete(legacy as CFDictionary)
    guard prior == errSecSuccess || prior == errSecItemNotFound else { finish(prior) }
    let result = SecItemDelete(current as CFDictionary)
    finish(result == errSecItemNotFound ? errSecSuccess : result)
case "restore":
    let (status, bytes) = read(legacy)
    guard status == errSecSuccess, let bytes else { finish(status == errSecSuccess ? errSecDecode : status) }
    SecKeychainSetUserInteractionAllowed(false)
    finish(save(bytes, to: current))
default:
    exit(64)
}
