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
        // appLocalizedString(_:), не String(localized:) — оно
        // вне тела View не видит .environment(\.locale:), берёт системный
        // язык вместо выбранного в приложении.
        switch self {
        case .notConfigured(let name):
            return appLocalizedString("%@ is not configured", name)
        case .quotaExceeded:
            return appLocalizedString("Daily cloud translation quota is used up")
        case .service(let msg):
            return msg
        case .badResponse:
            return appLocalizedString("Cloud translator returned an unexpected response")
        case .notSupported:
            return appLocalizedString("Translation not supported for this language pair")
        }
    }
}

/// Политика повторов для отдельных чанков: сетевой сбой или 5xx вычитает
/// из перевода один чанк, а не весь текст (на 100k символов это 200+
/// запросов, и без повторов одна случайная 503 обнуляла часы работы).
/// Нест транзиентное — `notSupported`, `quotaExceeded`, `notConfigured`,
/// 401/403: повторить всегда можно, толку никогда, падаем в цепочку сразу.
enum ChunkRetry {
    static let attempts = 3
    /// Сколько чанков гоним параллельно в `translateChunked`.
    static let windowSize = 3

    static func isTransient(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let e = error as? TranslationProviderError {
            switch e {
            case .badResponse: return true
            case .service(let msg):
                return ["(500)", "(502)", "(503)", "(504)"].contains { msg.contains($0) }
            case .notConfigured, .quotaExceeded, .notSupported:
                return false
            }
        }
        if let e = error as? CloudTranslator.Failure {
            switch e {
            case .badResponse: return true
            case .quotaExceeded, .service: return false
            }
        }
        if let e = error as? URLError {
            switch e.code {
            case .timedOut, .networkConnectionLost, .cannotConnectToHost,
                 .cannotFindHost, .notConnectedToInternet, .secureConnectionFailed:
                return true
            default:
                return false
            }
        }
        return false
    }
}

extension TranslationProvider {
    /// Общий цикл нарезки: чанки переводятся параллельно (окно в 3 заявки —
    /// 10k символов через LLM последовательными волнами шли минутами),
    /// порядок склейки сохраняется исходными переносами. Один чанк = одна
    /// заявка с повторами по `ChunkRetry.isTransient`: сетевой сбой или 5xx
    /// вычитает из перевода один чанк, а не весь текст.
    func translateChunked(
        _ text: String,
        from source: String,
        to target: String,
        _ translate: @escaping @Sendable (String) async throws -> String
    ) async throws -> String {
        let pieces = TextChunker.pieces(text, limit: charLimit)
        guard !pieces.isEmpty else { return "" }
        if pieces.count == 1 {
            return try await translateWithRetry(pieces[0].text, translate) + pieces[0].trailing
        }

        return try await withThrowingTaskGroup(of: (Int, String).self) { group in
            var started = 0
            while started < pieces.count, started < ChunkRetry.windowSize {
                let index = started
                started += 1
                group.addTask {
                    (index, try await self.translateWithRetry(pieces[index].text, translate))
                }
            }
            var results = [String](repeating: "", count: pieces.count)
            for try await (index, translated) in group {
                results[index] = translated + pieces[index].trailing
                if started < pieces.count {
                    let next = started
                    started += 1
                    group.addTask {
                        (next, try await self.translateWithRetry(pieces[next].text, translate))
                    }
                }
            }
            return results.joined()
        }
    }

    private func translateWithRetry(
        _ text: String,
        _ translate: @Sendable (String) async throws -> String
    ) async throws -> String {
        var lastError: (any Error)?
        for attempt in 0..<ChunkRetry.attempts {
            do {
                return try await translate(text)
            } catch let error where ChunkRetry.isTransient(error) {
                lastError = error
                guard attempt < ChunkRetry.attempts - 1 else { break }
                try await Task.sleep(for: .milliseconds(500 * (1 << attempt)))
            }
        }
        throw lastError ?? TranslationProviderError.badResponse
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
/// запросу пользователя. Yandex и LibreTranslate в первых версиях были,
/// затем убраны (у Yandex не было бесплатного тира, публичный инстанс
/// LibreTranslate переехал и стал платным). Вернулись осознанно: оба как
/// полноценные ключевые провайдеры — Yandex Cloud Translate (постоянный
/// API-ключ сервисного аккаунта) и LibreTranslate (свой URL инстанса,
/// ключ опционален для self-hosted).
enum EngineMode: String, CaseIterable, Sendable {
    case appleOnly = "apple"
    case appleMyMemory = "apple_mymemory"
    case azureCloud = "azure_cloud"
    case googleCloud = "google_cloud"
    case deepLCloud = "deepl_cloud"
    case openAICompatible = "openai_compat"
    case yandexCloud = "yandex_cloud"
    case libreTranslate = "libretranslate"

    static var pickerCases: [EngineMode] {
        [.appleOnly, .appleMyMemory, .azureCloud, .googleCloud, .deepLCloud,
         .openAICompatible, .yandexCloud, .libreTranslate]
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
        case .deepLCloud:
            return "DeepL"
        case .openAICompatible:
            return "OpenAI"
        case .yandexCloud:
            return "Yandex"
        case .libreTranslate:
            return "LibreTranslate"
        }
    }

    // Ключи для наблюдаемой локализации: view читает model.localizedString(key)
    // вместо прямого appLocalizedString, иначе Picker не инвалидируется при смене appLocale
    var displayNameKey: String {
        switch self {
        case .appleOnly: return "Apple Translation only"
        case .appleMyMemory: return "Apple + MyMemory"
        case .azureCloud: return "Cloud models (Azure)"
        case .googleCloud: return "Cloud models (Google)"
        case .deepLCloud: return "Cloud models (DeepL)"
        case .openAICompatible: return "Cloud models (OpenAI)"
        case .yandexCloud: return "Cloud models (Yandex)"
        case .libreTranslate: return "LibreTranslate"
        }
    }

    var descriptionKey: String {
        switch self {
        case .appleOnly: return "On-device. No network."
        case .appleMyMemory: return "Apple, then MyMemory for unsupported pairs."
        case .azureCloud: return "Azure Translator. Requires a key."
        case .googleCloud: return "Google Translate. Requires a key, billed past free tier."
        case .deepLCloud: return "DeepL. Requires a key."
        case .openAICompatible: return "OpenAI-compatible API. Requires base URL, key and model."
        case .yandexCloud: return "Yandex Cloud Translate. Requires an API key, billed per character."
        case .libreTranslate: return "LibreTranslate instance. Own URL, key optional on self-hosted."
        }
    }

    // Legacy non-observed — оставить для ошибок провайдеров вне View
    var displayName: String {
        switch self {
        case .appleOnly:
            return appLocalizedString("Apple Translation only")
        case .appleMyMemory:
            return appLocalizedString("Apple + MyMemory")
        case .azureCloud:
            return appLocalizedString("Cloud models (Azure)")
        case .googleCloud:
            return appLocalizedString("Cloud models (Google)")
        case .deepLCloud:
            return appLocalizedString("Cloud models (DeepL)")
        case .openAICompatible:
            return appLocalizedString("Cloud models (OpenAI)")
        case .yandexCloud:
            return appLocalizedString("Cloud models (Yandex)")
        case .libreTranslate:
            return appLocalizedString("LibreTranslate")
        }
    }

    var description: String {
        switch self {
        case .appleOnly:
            return appLocalizedString("On-device. No network.")
        case .appleMyMemory:
            return appLocalizedString("Apple, then MyMemory for unsupported pairs.")
        case .azureCloud:
            return appLocalizedString("Azure Translator. Requires a key.")
        case .googleCloud:
            return appLocalizedString("Google Translate. Requires a key, billed past free tier.")
        case .deepLCloud:
            return appLocalizedString("DeepL. Requires a key.")
        case .openAICompatible:
            return appLocalizedString("OpenAI-compatible API. Requires base URL, key and model.")
        case .yandexCloud:
            return appLocalizedString("Yandex Cloud Translate. Requires an API key, billed per character.")
        case .libreTranslate:
            return appLocalizedString("LibreTranslate instance. Own URL, key optional on self-hosted.")
        }
    }

    /// Legacy-значения из версий с Local OPUS, парой A/B и HuggingFace.
    /// `local_only`/`apple_local` теряют офлайн-часть и откатываются на
    /// Apple; `hf_cloud` — на MyMemory, у которого нет ни ключа, ни
    /// гео-блокировок. `yandex_cloud` больше не миграция: raw вернулся в
    /// качестве реального режима, старый юзер без ключа получит цепочку
    /// «Yandex → MyMemory», где MyMemory честно подхватит.
    static func migrated(from raw: String) -> EngineMode? {
        switch raw {
        case "local_only", "apple_local":
            return .appleOnly
        case "apple_local_cloud", "hf_cloud":
            return .appleMyMemory
        default:
            return EngineMode(rawValue: raw)
        }
    }
}

/// Языки для каждого движка — используются для динамических меню.
/// Источник: Apple Translation 22 языка, MyMemory ~100, Azure/Google —
/// официальные списки целиком, DeepL — стабильное ядро (см. комментарий у
/// deepLCodes).
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

    /// DeepL — WebFetch к developers.deepl.com/docs дал два противоречивых
    /// результата на один и тот же список языков (один раз «70+
    /// дополнительных» без перечисления, другой раз ~130 кодов с
    /// диалектными вариантами) — похоже на потери в суммаризаторе, а не на
    /// достоверный источник, транскрибировать 1-в-1 как официальный список
    /// (как сделано для Azure/Google) нельзя. Взято хорошо
    /// задокументированное стабильное ядро, которое DeepL поддерживал
    /// годами до расширения 2025+. Как и с Yandex раньше: не выдумываем
    /// полный список, реальную поддержку пары решает ответ сервера —
    /// неподдержанная пара честно падает notSupported и уходит в MyMemory.
    static let deepLCodes = [
        "ar","bg","cs","da","de","el","en","es","et","fi","fr","he","hu",
        "id","it","ja","ko","lt","lv","nb","nl","pl","pt","ro","ru","sk",
        "sl","sv","ta","tr","uk","vi","zh",
    ]

    /// Yandex Cloud Translate — политика как у DeepL: берётся проверенное
    /// ядро, полный официальный список (yandex.cloud/docs/translate/concepts/
    /// language) без живого ключа не снять (ListLanguages требует folderId и
    /// авторизации). Сервер решает, поддержана ли пара: неподдержанная даёт
    /// 400 и честно уходит в MyMemory.
    static let yandexCodes = [
        "en","ru","uk","be","de","fr","es","it","pt","pl","nl","cs","sk","sl","hr","bs","sr",
        "bg","ro","hu","da","no","fi","sv","et","lv","lt","tr","az","kk","ky","tg","tk","uz",
        "hy","ka","zh","ja","ko","ar","he","hi","bn","fa","ur","id","ms","th","vi","el","ga",
        "is","ca","eu","gl","la","mn","af","am","ne","si","sw","yo","ha","so","km","lo","my",
        "ta","te","kn","ml","mr","gu","pa","cv","ba","tt","sah","udm","mhr",
    ]

    /// LibreTranslate — ядро Argos Translate: языки с рабочими моделями в
    /// публичном инстансе. Остальные коды у разных инстансов отличаются
    /// (зависит от докачанных моделей) — сервер решает, при неподдержанной
    /// паре даёт ошибку, цепочка уходит в MyMemory (политика DeepL).
    static let libreTranslateCodes = [
        "en","ru","uk","de","fr","es","it","pt","pl","nl","cs","sk","sl","hr","bg","ro","hu",
        "da","no","fi","sv","et","lv","lt","tr","el","he","ar","fa","zh","ja","ko","vi","id",
        "ms","hi","bn","ta","te","th","ca","eu","gl","la","eo","ga","is","af","sw","ku",
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
        case .azureCloud:
            return azureCodes
        case .googleCloud:
            return googleCodes
        case .deepLCloud:
            return deepLCodes
        case .openAICompatible:
            // LLM — любые пары, отдаём самый широкий набор как у Google
            return googleCodes
        case .yandexCloud:
            return yandexCodes
        case .libreTranslate:
            return libreTranslateCodes
        }
    }
}
