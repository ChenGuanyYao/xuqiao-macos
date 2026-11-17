import Foundation
import Security
import LocalAuthentication

/// Keychain 中保存 CA 私钥和凭据摘要；普通偏好中不保存任何配对秘密。
final class SecureStore {
    let service: String
    init(suffix: String) { service = "com.chenguangyao.xuqiao.mac" + (suffix.isEmpty ? "" : ".debug.\(suffix)") }
    private func query(_ account: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }
    func read(_ account: String) throws -> Data? {
        var q = query(account); q[kSecReturnData as String] = true; q[kSecMatchLimit as String] = kSecMatchLimitOne
        #if DEBUG
        // 无界面测试不能悬挂在旧 ad hoc 签名的钥匙串授权弹窗上；使用独立后缀或明确失败。
        if service.contains(".debug.") {
            let context = LAContext(); context.interactionNotAllowed = true
            q[kSecUseAuthenticationContext as String] = context
        }
        #endif
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw CoreFailure("无法读取钥匙串（\(status)），请检查钥匙串是否已解锁") }
        return data
    }
    func write(_ account: String, data: Data) throws {
        let q = query(account)
        var status = SecItemUpdate(q as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = q; add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            status = SecItemAdd(add as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CoreFailure("无法保存钥匙串（\(status)），本次信任未保存") }
    }
    func readJSON<T: Decodable>(_ account: String, as: T.Type) throws -> T? {
        guard let data = try read(account) else { return nil }; return try JSONDecoder().decode(T.self, from: data)
    }
    func writeJSON<T: Encodable>(_ account: String, value: T) throws { try write(account, data: JSONEncoder().encode(value)) }
}
