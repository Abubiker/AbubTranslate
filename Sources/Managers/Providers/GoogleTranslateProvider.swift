import Foundation

/// Google Cloud Translation API (Basic/v2) — облачный движок, требует
/// API-ключ. Платный сверх бесплатного лимита, физического барьера от
/// списания денег (как F0 у Azure) здесь нет — по прямой просьбе
/// пользователя риск лимитов оставлен на его стороне, без клиентского
/// счётчика в приложении (ненадёжен, платформенной квоты Google не заменит —
/// см. обсуждение в README).
///
/// Контракт собран по официальной документации Google Cloud, НЕ живым
/// запросом: создание GCP-проекта с биллингом требует карту, это действие
/// приложение не может выполнить за пользователя.
/// docs.cloud.google.com/translate/docs/reference/rest/v2/translate
struct GoogleTranslateProvider: TranslationProvider {
    let id = "google"
    let name = "Google Translate"
    /// Google лимитирует запрос 30 000 кодовых точек суммарно по всем `q`;
    /// один чанк на элемент, берём с большим запасом.
    let charLimit = 4000

    var key: String? { KeychainHelper.googleKey }

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

        var components = URLComponents(string: "https://translation.googleapis.com/language/translate/v2")!
        components.queryItems = [URLQueryItem(name: "key", value: k)]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "q": chunk,
            "target": target,
            "source": source,
            "format": "text",
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationProviderError.badResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }

        guard let decoded = try? JSONDecoder().decode(GoogleResponse.self, from: data),
              let text = decoded.data.translations.first?.translatedText, !text.isEmpty
        else {
            throw TranslationProviderError.badResponse
        }
        return text
    }

    /// Формат: {"error":{"code":400,"message":"...","errors":[{"reason":"..."}]}}.
    /// reason "invalidLanguagePair" — честный notSupported, а не общая
    /// service-ошибка, чтобы цепочка ушла в MyMemory, а не ретраила.
    private func mapError(status: Int, data: Data) -> TranslationProviderError {
        struct GoogleError: Decodable {
            struct Inner: Decodable {
                struct Detail: Decodable { let reason: String? }
                let code: Int
                let message: String
                let errors: [Detail]?
            }
            let error: Inner
        }
        let decoded = try? JSONDecoder().decode(GoogleError.self, from: data)
        let reason = decoded?.error.errors?.first?.reason
        let message = decoded?.error.message ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"

        if status == 403, message.uppercased().contains("QUOTA") {
            return .quotaExceeded
        }
        if reason == "invalidLanguagePair" || reason == "invalidTarget" {
            return .notSupported
        }
        return .service("Google (\(status)): \(message)")
    }

    private struct GoogleResponse: Decodable {
        struct Translation: Decodable { let translatedText: String }
        struct Payload: Decodable { let translations: [Translation] }
        let data: Payload
    }
}
