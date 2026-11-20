import Foundation
import Security

let arguments = CommandLine.arguments
guard arguments.count == 3 else { exit(64) }
let action = arguments[1]
let path = arguments[2]
let query: [String: Any] = [
    kSecClass as String: kSecClassGenericPassword,
    kSecAttrService as String: "local.codex-api-workbench.release-signing",
    kSecAttrAccount as String: "keychain-password"
]

func requireSuccess(_ status: OSStatus) {
    guard status == errSecSuccess else {
        FileHandle.standardError.write(Data("无法使用工作台的专用签名钥匙串（\(status)）。\n".utf8))
        exit(1)
    }
}

var chain: SecKeychain?
if action == "open", !FileManager.default.fileExists(atPath: path) {
    var random = Data(count: 32)
    requireSuccess(random.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) })
    let password = Data(random.base64EncodedString().utf8)
    requireSuccess(path.withCString { name in
        password.withUnsafeBytes { SecKeychainCreate(name, UInt32(password.count), $0.baseAddress, false, nil, &chain) }
    })
    var item = query
    item[kSecAttrLabel as String] = "Codex API 工作台发布签名"
    item[kSecValueData as String] = password
    let status = SecItemAdd(item as CFDictionary, nil)
    if status != errSecSuccess {
        if let chain { SecKeychainDelete(chain) }
        requireSuccess(status)
    }
    exit(0)
}

requireSuccess(path.withCString { SecKeychainOpen($0, &chain) })
guard let chain else { exit(1) }
if action == "lock" {
    requireSuccess(SecKeychainLock(chain))
} else if action == "open" {
    var request = query
    request[kSecReturnData as String] = true
    request[kSecMatchLimit as String] = kSecMatchLimitOne
    var result: CFTypeRef?
    requireSuccess(SecItemCopyMatching(request as CFDictionary, &result))
    guard let password = result as? Data, !password.isEmpty else { exit(1) }
    requireSuccess(password.withUnsafeBytes { SecKeychainUnlock(chain, UInt32(password.count), $0.baseAddress, true) })
} else {
    exit(64)
}
