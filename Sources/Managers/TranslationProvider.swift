import Foundation

/// Общий протокол для всех облачных переводчиков.
/// Позволяет AppModel перебирать цепочку провайдеров по приоритету,
/// пока один не вернёт результат.
protocol TranslationProvider: Sendable {
    var id: String { get }
    var name: String { get }
    /// Лимит символов на один запрос у сервиса.
    var charLimit: Int { get }
    /// Требует ли провайдер ключ/токен для работы.
    var requiresKey: Bool { get }
    /// Проверка — настроен ли провайдер (есть ключ если нужен).
    func isConfigured() -> Bool
    func translate(_ text: String, from source: String, to target: String) async throws -> String
}

enum TranslationProviderError: LocalizedError {
    case notConfigured(String)
    case quotaExceeded
    case service(String)
    case badResponse
    case notSupported

    var errorDescription: String? {
        switch self {
        case .notConfigured(let name):
            return String(localized: "\(name) is not configured")
        case .quotaExceeded:
            return String(localized: "Daily cloud translation quota is used up")
        case .service(let msg):
            return msg
        case .badResponse:
            return String(localized: "Cloud translator returned an unexpected response")
        case .notSupported:
            return String(localized: "Translation not supported for this language pair")
        }
    }
}

/// Выбор движка — главный переключатель в настройках.
/// 4 основных режима по запросу: только Apple, Apple+MyMemory, только локальная OPUS, облако HF.
/// Старые `apple_local` / `apple_local_cloud` оставлены для миграции.
enum EngineMode: String, CaseIterable, Sendable {
    case appleOnly = "apple"
    case appleMyMemory = "apple_mymemory"
    case localOnly = "local_only"
    case hfCloud = "hf_cloud"
    // Legacy (скрыты из пикера, но парсятся для миграции)
    case appleLocal = "apple_local"
    case appleLocalCloud = "apple_local_cloud"

    /// Только новые 4 пункта для показа в Settings.
    static var pickerCases: [EngineMode] {
        [.appleOnly, .appleMyMemory, .localOnly, .hfCloud]
    }

    var displayName: String {
        switch self {
        case .appleOnly:
            return String(localized: "Apple Translation only")
        case .appleMyMemory:
            return String(localized: "Apple + MyMemory")
        case .localOnly:
            return String(localized: "Local neural only (OPUS)")
        case .hfCloud:
            return String(localized: "Cloud models (HuggingFace)")
        case .appleLocal:
            return String(localized: "Apple + Local neural (OPUS)")
        case .appleLocalCloud:
            return String(localized: "Apple + Local + Cloud fallback")
        }
    }

    var description: String {
        switch self {
        case .appleOnly:
            return String(localized: "Only on-device Apple Translation. No network requests.")
        case .appleMyMemory:
            return String(localized: "Apple first, MyMemory fallback for unsupported pairs. Free, works in Russia. Optional email raises quota.")
        case .localOnly:
            return String(localized: "Only offline OPUS models. Download models below. No network requests, ~150MB RAM during translation.")
        case .hfCloud:
            return String(localized: "Cloud HuggingFace (NLLB/OPUS). Works in Russia, free without card. Optional HF token raises limits. Text leaves your Mac.")
        case .appleLocal:
            return String(localized: "Adds offline OPUS models for unsupported languages. Download models in the section below.")
        case .appleLocalCloud:
            return String(localized: "Adds local models and, if they are missing, cloud providers as last resort. Text may leave your Mac.")
        }
    }

    /// Нужен ли ключ для этого режима (показываем поле ключа).
    var requiresKey: Bool {
        switch self {
        case .hfCloud: return false // работает без токена, но с токеном лучше — показываем поле всё равно
        case .appleMyMemory: return false // email опционально
        default: return false
        }
    }

    /// Миграция legacy -> новые 4.
    static func migrated(from raw: String) -> EngineMode? {
        if let direct = EngineMode(rawValue: raw) {
            // Старые appleLocal/appleLocalCloud мапим на новые ближайшие
            switch direct {
            case .appleLocal: return .localOnly
            case .appleLocalCloud: return .hfCloud
            default: return direct
            }
        }
        return nil
    }
}

/// Языки для каждого движка — используются для динамических меню.
/// Источник: Apple Translation 22 языка, MyMemory ~100, OPUS ~50, HF NLLB 200.
enum EngineLanguageSupport {
    /// Apple Translation на этом Mac (динамический, но fallback для UI до загрузки).
    /// Дублирует AppModel.fallbackLanguageCodes чтобы не тянуть @MainActor зависимость.
    static let appleFallback = [
        "ru", "en", "uk", "de", "fr", "es", "it", "pt",
        "zh", "ja", "ko", "ar", "tr", "pl", "nl", "cs",
    ]

    /// MyMemory поддерживает практически все ISO коды — берём широкий набор.
    static let myMemoryCodes = [
        "ru","en","uk","de","fr","es","it","pt","zh","ja","ko","ar","tr","pl","nl","cs",
        "fi","sv","da","nb","el","he","fa","ur","hi","bn","ta","te","th","vi","id","ms",
        "sw","am","eu","ca","gl","ro","hu","bg","hr","sr","sk","sl","et","lv","lt","be",
        "kk","ky","uz","az","ka","hy","sq","bs","mk","is","ga","cy","af","zu","mt","si",
    ]

    /// OPUS-MT Helsinki — около 50 популярных пар, покрывает API интеграции.
    static let opusCodes = [
        "ru","en","de","fr","es","it","pt","zh","ja","ko","ar","tr","pl","nl","cs",
        "uk","fi","sv","da","nb","el","he","fa","ur","hi","bn","th","vi","id","ms",
        "sw","ro","hu","bg","hr","sr","sk","sl","et","lv","lt","be","kk","uz","az",
        "ka","hy","sq","bs","mk","is",
    ]

    /// HuggingFace NLLB 200 — полный Flores-200 список (сокращённо 80 самых частых для UI).
    static let hfCodes = [
        "en","ru","de","fr","es","it","pt","zh","ja","ko","ar","tr","pl","nl","cs","uk",
        "sv","da","nb","fi","el","he","fa","ur","hi","bn","ta","te","th","vi","id","ms",
        "sw","am","eu","ca","gl","ro","hu","bg","hr","sr","sk","sl","et","lv","lt","be",
        "kk","ky","uz","az","ka","hy","sq","bs","mk","is","ga","cy","af","zu","mt","si",
        "ml","gu","kn","pa","sd","ne","si","lo","my","km","mn","bo","ug","ps","ku","tk",
        "tg","tt","ba","cv","ce","yi","jv","su","tl","haw","mi","sm","to","fj",
    ]

    static func codes(for mode: EngineMode, appleAvailable: [String]) -> [String] {
        switch mode {
        case .appleOnly:
            return appleAvailable.isEmpty ? appleFallback : appleAvailable
        case .appleMyMemory:
            // Объединяем Apple + MyMemory широкий набор, без дублей, сортируем по имени
            var set = Set(appleAvailable.isEmpty ? appleFallback : appleAvailable)
            set.formUnion(myMemoryCodes)
            return Array(set)
        case .localOnly:
            return opusCodes
        case .hfCloud:
            return hfCodes
        case .appleLocal:
            return opusCodes
        case .appleLocalCloud:
            var set = Set(hfCodes)
            set.formUnion(opusCodes)
            return Array(set)
        }
    }
}
