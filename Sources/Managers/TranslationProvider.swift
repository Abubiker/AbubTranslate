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
///
/// HuggingFace как движок тоже убран (не из-за него самого — работал
/// нормально после смены модели на Helsinki-NLP opus-mt) — по прямому
/// запросу пользователя, финальный набор: Apple / Apple+MyMemory / Azure /
/// Google / Yandex.
enum EngineMode: String, CaseIterable, Sendable {
    case appleOnly = "apple"
    case appleMyMemory = "apple_mymemory"
    case azureCloud = "azure_cloud"
    case googleCloud = "google_cloud"
    case yandexCloud = "yandex_cloud"

    static var pickerCases: [EngineMode] {
        [.appleOnly, .appleMyMemory, .azureCloud, .googleCloud, .yandexCloud]
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
        case .azureCloud:
            return "Azure Translator"
        case .googleCloud:
            return "Google Translate"
        case .yandexCloud:
            return "Yandex Translate"
        }
    }

    var displayName: String {
        switch self {
        case .appleOnly:
            return String(localized: "Apple Translation only")
        case .appleMyMemory:
            return String(localized: "Apple + MyMemory")
        case .azureCloud:
            return String(localized: "Cloud models (Azure)")
        case .googleCloud:
            return String(localized: "Cloud models (Google)")
        case .yandexCloud:
            return String(localized: "Cloud models (Yandex)")
        }
    }

    var description: String {
        switch self {
        case .appleOnly:
            return String(localized: "On-device. No network.")
        case .appleMyMemory:
            return String(localized: "Apple, then MyMemory for unsupported pairs.")
        case .azureCloud:
            return String(localized: "Azure Translator. Requires a key.")
        case .googleCloud:
            return String(localized: "Google Translate. Requires a key, billed past free tier.")
        case .yandexCloud:
            return String(localized: "Yandex Translate. Requires a key and a folder ID.")
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
        case "apple_local_cloud", "hf_cloud":
            // HuggingFace убран из приложения — кто был на нём, откатывается
            // на бесплатный движок без ключа, а не на первый попавшийся.
            return .appleMyMemory
        default:
            return EngineMode(rawValue: raw)
        }
    }
}

/// Языки для каждого движка — используются для динамических меню.
/// Источник: Apple Translation 22 языка, MyMemory ~100, Azure/Google —
/// официальные списки целиком, Yandex — приближение (см. комментарий у
/// yandexCodes).
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

    /// Полный список Azure Translator (text translation), простые коды без
    /// диалектных вариантов (fr-ca, pt-pt, zh-Hant, sr-Cyrl и т.п. опущены —
    /// остальные списки в файле тоже держат один код на язык). Источник:
    /// learn.microsoft.com/azure/ai-services/translator/language-support,
    /// колонка "Cloud – Text translation", снято целиком 2026-08-27.
    static let azureCodes = [
        "af","sq","am","ar","hy","as","az","bn","ba","eu","bho","brx","bs","bg","yue","ca",
        "hne","lzh","zh","sn","hr","cs","da","prs","dv","doi","nl","en","et","fo","fj","fil",
        "fi","fr","gl","ka","de","el","gu","ht","ha","he","hi","mww","hu","is","ig","id","ikt",
        "iu","ga","it","ja","kn","ks","kk","km","rw","gom","ko","ku","kmr","ky","lo","lv","lt",
        "ln","dsb","lug","mk","mai","mg","ms","ml","mt","mni","mi","mr","mn","my","ne","nb",
        "nya","or","ps","fa","pl","pt","pa","otq","ro","run","ru","sm","sr","st","nso","tn",
        "sd","si","sk","sl","so","es","sw","sv","ty","ta","tt","te","th","bo","ti","to","tr",
        "tk","uk","hsb","ur","ug","uz","vi","cy","xh","yo","yua","zu",
    ]

    /// Google Cloud Translation (NMT) — самый широкий список из всех
    /// движков. Простые коды без региональных/скриптовых вариантов
    /// (zh-CN/zh-TW → "zh", fr-FR/fr-CA → "fr", pt-PT/pt-BR → "pt",
    /// ms-Arab/pa-Arab/mni-Mtei опущены — тот же принцип, что у остальных
    /// списков в файле). Источник: docs.cloud.google.com/translate/docs/languages,
    /// раздел NMT, снято целиком 2026-08-27.
    static let googleCodes = [
        "ab","ace","ach","af","sq","alz","am","ar","hy","as","awa","ay","az","ban","bm","ba",
        "eu","btx","bts","bbc","be","bem","bn","bew","bho","bik","bs","br","bg","bua","yue","ca",
        "ceb","ny","zh","cv","co","crh","hr","cs","da","din","dv","doi","dov","nl","dz","en",
        "eo","et","ee","fj","fil","tl","fi","fr","fy","ff","gaa","gl","lg","ka","de","el",
        "gn","gu","ht","cnh","ha","haw","he","hil","hi","hmn","hu","hrx","is","ig","ilo","id",
        "ga","it","ja","jw","jv","kn","pam","kk","km","cgg","rw","ktu","gom","ko","kri","ku",
        "ckb","ky","lo","ltg","la","lv","lij","li","ln","lt","lmo","luo","lb","mk","mai","mak",
        "mg","ms","ml","mt","mi","mr","chm","min","lus","mn","my","nr","new","ne","no","nus",
        "oc","or","om","pag","pap","ps","fa","pl","pt","pa","qu","rom","ro","rn","ru","sm",
        "sg","sa","gd","sr","st","crs","shn","sn","scn","szl","sd","si","sk","sl","so","es",
        "su","sw","ss","sv","tg","ta","tt","te","tet","th","ti","ts","tn","tr","tk","ak",
        "uk","ur","ug","uz","vi","cy","xh","yi","yo","yua","zu",
    ]

    /// Yandex Translate — официальный список языков недоступен: страницы
    /// yandex.cloud/aistudio.yandex.ru блокируют автоматические запросы
    /// CAPTCHA, а подтверждено только «114 языков, ISO 639-1» без полного
    /// перечня. Не выдумываем список — переиспользуем уже проверенный
    /// широкий набор myMemoryCodes как приближение для UI. Как и с opus-mt
    /// в HuggingFace раньше: реальную поддержку пары решает ответ сервера,
    /// неподдержанная пара честно падает notSupported и уходит в MyMemory.
    static var yandexCodes: [String] { myMemoryCodes }

    static func codes(for mode: EngineMode, appleAvailable: [String]) -> [String] {
        switch mode {
        case .appleOnly:
            return appleAvailable.isEmpty ? appleFallback : appleAvailable
        case .appleMyMemory:
            // Объединяем Apple + MyMemory широкий набор, без дублей, сортируем по имени
            var set = Set(appleAvailable.isEmpty ? appleFallback : appleAvailable)
            set.formUnion(myMemoryCodes)
            return Array(set)
        case .azureCloud:
            return azureCodes
        case .googleCloud:
            return googleCodes
        case .yandexCloud:
            return yandexCodes
        }
    }
}
