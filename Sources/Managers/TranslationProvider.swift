import Foundation

/// Общий протокол для всех облачных переводчиков.
/// Позволяет AppModel перебирать цепочку провайдеров по приоритету,
/// пока один не вернёт результат.
protocol TranslationProvider: Sendable {
    var id: String { get }
    var name: String { get }
    /// Лимит символов на один запрос у сервиса.
    var charLimit: Int { get }
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
///
/// Local OPUS убран целиком: скачивание шло с
/// `huggingface.co/coreml-community/opus-mt-*`, а такой организации моделей
/// перевода никогда не существовало — проверено через API HuggingFace,
/// `coreml-community` содержит только конвертации Stable Diffusion, ноль
/// репозиториев перевода. Любая пара падала бы 404 при первом же скачивании.
enum EngineMode: String, CaseIterable, Sendable {
    case appleOnly = "apple"
    case appleMyMemory = "apple_mymemory"
    case hfCloud = "hf_cloud"

    static var pickerCases: [EngineMode] {
        [.appleOnly, .appleMyMemory, .hfCloud]
    }

    /// Имя провайдера, который в этом режиме пробуется первым — сравнивается
    /// с фактически сработавшим (`AppModel.lastProviderName`), чтобы отличить
    /// «основной провайдер сработал» от «ушли в запасной внутри цепочки».
    var primaryProviderName: String? {
        switch self {
        case .appleOnly:
            return nil
        case .appleMyMemory:
            return "MyMemory"
        case .hfCloud:
            return "HuggingFace"
        }
    }

    var displayName: String {
        switch self {
        case .appleOnly:
            return String(localized: "Apple Translation only")
        case .appleMyMemory:
            return String(localized: "Apple + MyMemory")
        case .hfCloud:
            return String(localized: "Cloud models (HuggingFace)")
        }
    }

    var description: String {
        switch self {
        case .appleOnly:
            return String(localized: "On-device. No network.")
        case .appleMyMemory:
            return String(localized: "Apple, then MyMemory for unsupported pairs.")
        case .hfCloud:
            return String(localized: "HuggingFace. Requires a token.")
        }
    }

    /// Legacy-значения из версий с Local OPUS и с парой A/B. `local_only` и
    /// `apple_local` теряют офлайн-часть и откатываются на Apple;
    /// `apple_local_cloud` — на HuggingFace, у него всё равно был этот же
    /// провайдер вторым шагом.
    static func migrated(from raw: String) -> EngineMode? {
        switch raw {
        case "local_only", "apple_local":
            return .appleOnly
        case "apple_local_cloud":
            return .hfCloud
        default:
            return EngineMode(rawValue: raw)
        }
    }
}

/// Языки для каждого движка — используются для динамических меню.
/// Источник: Apple Translation 22 языка, MyMemory ~100, HF — по паре Helsinki-NLP opus-mt.
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

    /// HuggingFace / Helsinki-NLP opus-mt — по паре языков, не все направления
    /// существуют (например en→ja, en→tr — проверено, живых моделей нет).
    /// Список для UI, реальную доступность решает ответ сервера (404 →
    /// TranslationProviderError.notSupported, цепочка уходит в MyMemory).
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
        case .hfCloud:
            return hfCodes
        }
    }
}
