import Foundation

/// Yandex Translate v2 — облачный движок, требует API-ключ и Folder ID
/// (идентификатор папки Yandex Cloud, отдельная сущность от ключа,
/// обязателен всегда, в отличие от опционального региона у Azure).
///
/// Официальные страницы yandex.cloud/aistudio.yandex.ru блокируют
/// автоматические запросы CAPTCHA — контракт НЕ подтверждён напрямую
/// официальной документацией. Восстановлен по открытому SDK
/// github.com/Ralstonnn/yandex-translate-v2-api и фрагментам официальных
/// доков в поисковой выдаче. Формат ошибки не подтверждён тем же путём —
/// обработка защитная, как у Azure/Google. Живым запросом не проверен:
/// создание Yandex Cloud аккаунта с платёжными данными приложение не может
/// выполнить за пользователя.
struct YandexTranslateProvider: TranslationProvider {
    let id = "yandex"
    let name = "Yandex Translate"
    let charLimit = 4000

    var key: String? { KeychainHelper.yandexKey }
    var folderId: String? { KeychainHelper.yandexFolderId }

    func isConfigured() -> Bool {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return false }
        guard let f = folderId?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty else { return false }
        return true
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        var parts: [String] = []
        for chunk in TextChunker.chunks(text, limit: charLimit) {
            try Task.checkCancellation()
            let translated = try await translateChunk(chunk, from: source, to: target)
            parts.append(translated)
        }
        return parts.joined(separator: " ")
    }

    private func translateChunk(_ chunk: String, from source: String, to target: String) async throws -> String {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty,
              let f = folderId?.trimmingCharacters(in: .whitespacesAndNewlines), !f.isEmpty
        else {
            throw TranslationProviderError.notConfigured(name)
        }

        var request = URLRequest(url: URL(string: "https://translate.api.cloud.yandex.net/translate/v2/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Api-Key \(k)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "sourceLanguageCode": source,
            "targetLanguageCode": target,
            "texts": [chunk],
            "folderId": f,
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationProviderError.badResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }

        guard let decoded = try? JSONDecoder().decode(YandexResponse.self, from: data),
              let text = decoded.translations.first?.text, !text.isEmpty
        else {
            throw TranslationProviderError.badResponse
        }
        return text
    }

    /// Формат ошибки не подтверждён (см. комментарий у типа) — пробуем
    /// общий вид {"code","message"}, иначе сырое тело.
    private func mapError(status: Int, data: Data) -> TranslationProviderError {
        struct YandexError: Decodable { let code: Int?; let message: String? }
        let decoded = try? JSONDecoder().decode(YandexError.self, from: data)
        let message = decoded?.message ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"

        if status == 401 || status == 403 {
            return .service("Yandex: \(message)")
        }
        if status == 429 {
            return .quotaExceeded
        }
        if status == 400, message.uppercased().contains("LANG") {
            return .notSupported
        }
        return .service("Yandex (\(status)): \(message)")
    }

    private struct YandexResponse: Decodable {
        struct Translation: Decodable { let text: String }
        let translations: [Translation]
    }
}
