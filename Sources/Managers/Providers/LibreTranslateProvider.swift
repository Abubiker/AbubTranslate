import Foundation

/// LibreTranslate — open-source переводчик, бесплатный без ключа.
/// Публичные инстансы работают в RU, но можно указать свой сервер.
/// API docs: https://github.com/LibreTranslate/LibreTranslate#api
struct LibreTranslateProvider: TranslationProvider {
    let id = "libretranslate"
    let name = "LibreTranslate"
    let charLimit = 900 // libretranslate.de лимит ~500, берём с запасом
    let requiresKey = false

    /// Кастом URL из настроек (Keychain). Если пусто — дефолтный публичный.
    var endpointURL: URL {
        if let custom = KeychainHelper.libreTranslateURL?.trimmingCharacters(in: .whitespacesAndNewlines),
           !custom.isEmpty, let url = URL(string: custom)
        {
            return url
        }
        // Публичный инстанс libretranslate.de — стабильный, без ключа
        return URL(string: "https://libretranslate.de/translate")!
    }

    var apiKey: String? {
        // Некоторые инстансы требуют ключ, но публичный — нет.
        // Если юзер использует свой сервер с ключом — можно хранить в Keychain как libre_api_key
        KeychainHelper.load(for: "libre_api_key")
    }

    func isConfigured() -> Bool {
        // Всегда можно пробовать — даже без кастом URL есть дефолт.
        // Но если юзер в режиме appleLocalCloud и хочет cloud, считаем configured.
        true
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        var parts: [String] = []
        for chunk in TextChunker.chunks(text, limit: charLimit) {
            try Task.checkCancellation()
            parts.append(try await translateChunk(chunk, from: source, to: target))
        }
        return parts.joined(separator: " ")
    }

    private func translateChunk(_ chunk: String, from source: String, to target: String) async throws -> String {
        var request = URLRequest(url: endpointURL)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        var payload: [String: Any] = [
            "q": chunk,
            "source": source,
            "target": target,
            "format": "text",
        ]
        if let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            payload["api_key"] = key
        }

        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationProviderError.badResponse
        }

        if http.statusCode == 429 {
            throw TranslationProviderError.quotaExceeded
        }
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            throw TranslationProviderError.service(msg)
        }

        guard let decoded = try? JSONDecoder().decode(LibreResponse.self, from: data),
              !decoded.translatedText.isEmpty
        else {
            throw TranslationProviderError.badResponse
        }
        return decoded.translatedText
    }

    private struct LibreResponse: Decodable {
        let translatedText: String
    }
}
