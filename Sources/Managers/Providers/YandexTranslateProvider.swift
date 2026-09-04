import Foundation

/// Yandex Cloud Translate API v2 — синхронный перевод, требует API-ключ
/// сервисного аккаунта со scope `yc.ai.translate.execute`
/// (`Authorization: Api-Key <ключ>`). Ключи обычным пользователям выдают
/// временные IAM-токены — они тут не принимаются; в настройках есть
/// отдельное поле folder ID, обязательное ровно для таких ключей.
///
/// Контракт подтверждён официальной документацией
/// yandex.cloud/docs/translate/api-ref/Translation/translate
/// (POST /translate/v2/translate, суммарный лимит 10 000 символов на
/// запрос, коды ISO-639-1 до 3 символов), НЕ живым запросом — регистрация
/// облачного аккаунта с картой невозможна за пользователя.
struct YandexTranslateProvider: TranslationProvider {
    let id = "yandex"
    let name = "Yandex"
    /// 10 000 символов суммарно на запрос — запас на JSON-экранирование.
    let charLimit = 9500

    var key: String? { KeychainHelper.yandexKey }
    var folderId: String? { UserDefaults.standard.string(forKey: "yandex_folder_id") }

    func isConfigured() -> Bool {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return false }
        return true
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translateChunked(text, from: source, to: target) {
            try await self.translateChunk($0, from: source, to: target)
        }
    }

    private func translateChunk(_ chunk: String, from source: String, to target: String) async throws -> String {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else {
            throw TranslationProviderError.notConfigured(name)
        }

        var body: [String: Any] = [
            "sourceLanguageCode": source,
            "targetLanguageCode": target,
            "texts": [chunk],
            "format": "PLAIN_TEXT",
        ]
        if let folder = folderId?.trimmingCharacters(in: .whitespacesAndNewlines), !folder.isEmpty {
            body["folderId"] = folder
        }

        var request = URLRequest(url: URL(string: "https://translate.api.cloud.yandex.net/translate/v2/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Api-Key \(k)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationProviderError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }

        struct YandexResponse: Decodable {
            struct Translation: Decodable { let text: String }
            let translations: [Translation]
        }
        guard let decoded = try? JSONDecoder().decode(YandexResponse.self, from: data),
              let text = decoded.translations.first?.text, !text.isEmpty
        else {
            throw TranslationProviderError.badResponse
        }
        return text
    }

    /// Формат ошибки Google-pb: {"code":400,"message":"..."}.
    /// 403/401 — ключ невалидный или нет scope; 429 — rate limit облака.
    private func mapError(status: Int, data: Data) -> TranslationProviderError {
        struct YandexError: Decodable { let code: Int; let message: String }
        let decoded = try? JSONDecoder().decode(YandexError.self, from: data)
        let message = decoded?.message ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"

        switch status {
        case 401, 403:
            return .service("Yandex (\(status)): \(message)")
        case 429:
            // По-минутный лимит облака переждивается бэк-оффом
            // (метка (429) для ChunkRetry), дневная квота — тоже, но
            // ретраи ограничены attempts, дальше честный откат.
            return .service("Yandex (429): \(message)")
        case 400:
            // Неподдерживаемый язык/пара приходит как 400 с внятным
            // сообщением — при неизвестном языке честнее в фолбэк, чем в
            // ретраи. Точные коды ошибок облако не документирует как
            // стабильные, поэтому фильтруем по тексту.
            let lower = message.lowercased()
            if lower.contains("language") || lower.contains("unsupported") {
                return .notSupported
            }
            return .service("Yandex (400): \(message)")
        default:
            return .service("Yandex (\(status)): \(message)")
        }
    }
}
