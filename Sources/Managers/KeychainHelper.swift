import Foundation
import Security

/// Простая обёртка над Keychain для хранения API ключей.
/// UserDefaults для секретов не подходит.
enum KeychainHelper {
    private static let service = "com.opensource.abubtranslate.keys"

    @discardableResult
    static func save(_ value: String, for key: String) -> OSStatus {
        let data = Data(value.utf8)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        guard !value.isEmpty else { return errSecSuccess }
        var addQuery = query
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("Keychain save failed \(key): \(status)")
        }
        return status
    }

    static func load(for key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
            kSecUseDataProtectionKeychain as String: true,
        ]
        var item: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecUnimplemented || status == errSecParam {
            var fallback = query
            fallback.removeValue(forKey: kSecUseDataProtectionKeychain as String)
            status = SecItemCopyMatching(fallback as CFDictionary, &item)
        }
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }

    // MARK: - Typed keys

    static var huggingFaceToken: String? {
        get { load(for: "hf_token") }
        set {
            if let v = newValue, !v.isEmpty { save(v, for: "hf_token") }
            else { delete(for: "hf_token") }
        }
    }

    /// Миграция старых UserDefaults ключей в Keychain (если были).
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        if let hf = defaults.string(forKey: "hfToken"), !hf.isEmpty {
            if load(for: "hf_token") == nil { save(hf, for: "hf_token") }
            defaults.removeObject(forKey: "hfToken")
        }
        defaults.removeObject(forKey: "libreTranslateURL")
        // LibreTranslate убран из приложения — публичный инстанс переехал
        // и стал платным. Подчищаем то, что могло остаться в Keychain
        // от предыдущих версий: без провайдера эти ключи мёртвый груз.
        delete(for: "libre_url")
        delete(for: "libre_api_key")
    }
}
