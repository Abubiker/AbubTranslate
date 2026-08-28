import Foundation
import Security

/// Простая обёртка над Keychain для хранения API ключей.
/// UserDefaults для секретов не подходит.
enum KeychainHelper {
    private static let service = "com.opensource.abubtranslate.keys"

    /// Без kSecUseDataProtectionKeychain — сознательно. Приложение не несёт
    /// entitlements-файла с keychain-access-group, а SecItemAdd с этим
    /// флагом на неподписанном такой группой процессе падает
    /// errSecMissingEntitlement (-34018), проверено вручную. Раньше save()
    /// писал без флага, а load() читал с ним — SecItemAdd тихо успевал,
    /// SecItemCopyMatching в другой связке ничего не находил: Save выглядел
    /// рабочим, токен пропадал молча. Симметрия — по проверенному рабочему
    /// пути, не по формально более новому API.
    private static func baseQuery(for key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    @discardableResult
    static func save(_ value: String, for key: String) -> OSStatus {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
        guard !value.isEmpty else { return errSecSuccess }

        var addQuery = baseQuery(for: key)
        addQuery[kSecValueData as String] = Data(value.utf8)
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        let status = SecItemAdd(addQuery as CFDictionary, nil)
        if status != errSecSuccess {
            NSLog("Keychain save failed \(key): \(status)")
        }
        return status
    }

    static func load(for key: String) -> String? {
        var query = baseQuery(for: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(for key: String) {
        SecItemDelete(baseQuery(for: key) as CFDictionary)
    }

    // MARK: - Typed keys

    static var azureKey: String? {
        get { load(for: "azure_key") }
        set {
            if let v = newValue, !v.isEmpty { save(v, for: "azure_key") }
            else { delete(for: "azure_key") }
        }
    }

    /// Не секрет (просто "westeurope" и т.п.), но хранится тут же для
    /// единообразия — тот же паттерн, что уже был у libre_url.
    static var azureRegion: String? {
        get { load(for: "azure_region") }
        set {
            if let v = newValue, !v.isEmpty { save(v, for: "azure_region") }
            else { delete(for: "azure_region") }
        }
    }

    static var googleKey: String? {
        get { load(for: "google_key") }
        set {
            if let v = newValue, !v.isEmpty { save(v, for: "google_key") }
            else { delete(for: "google_key") }
        }
    }

    static var deepLKey: String? {
        get { load(for: "deepl_key") }
        set {
            if let v = newValue, !v.isEmpty { save(v, for: "deepl_key") }
            else { delete(for: "deepl_key") }
        }
    }

    /// Миграция старых UserDefaults ключей в Keychain (если были).
    static func migrateIfNeeded() {
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: "hfToken")
        // HuggingFace убран из приложения — подчищаем то, что могло
        // остаться в Keychain от предыдущих версий: без провайдера этот
        // ключ мёртвый груз.
        delete(for: "hf_token")
        defaults.removeObject(forKey: "libreTranslateURL")
        // LibreTranslate убран из приложения — публичный инстанс переехал
        // и стал платным. Подчищаем то, что могло остаться в Keychain
        // от предыдущих версий: без провайдера эти ключи мёртвый груз.
        delete(for: "libre_url")
        delete(for: "libre_api_key")
        // Yandex убран из приложения — нет постоянного бесплатного тира,
        // решили не держать ради формальности. Та же чистка осиротевших
        // значений.
        delete(for: "yandex_key")
        delete(for: "yandex_folder_id")
    }
}
