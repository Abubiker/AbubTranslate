import Foundation

/// HuggingFace Inference Providers — облачная нейронка, требует токен.
/// Docs: https://huggingface.co/docs/inference-providers
///
/// Модель выбирается ПО ПАРЕ языков: `Helsinki-NLP/opus-mt-{src}-{tgt}`.
/// Раньше использовалась одна универсальная модель на 200 языков
/// (facebook/nllb-200-distilled-600M), но HuggingFace вывел её из системы
/// Inference Providers — `inferenceProviderMapping` для неё теперь пустой
/// объект у всех, не только у нас, проверено через
/// `huggingface.co/api/models/facebook/nllb-200-distilled-600M?expand=inferenceProviderMapping`.
/// Запрос с валидным токеном возвращал не 401, а
/// `{"error":"Model not supported by provider hf-inference"}` — токен был
/// ни при чём, требуется откат к моделям для (src, tgt), а
/// Helsinki-NLP/opus-mt-* по большинству популярных пар в системе `live`.
struct HuggingFaceProvider: TranslationProvider {
    let id = "huggingface"
    let name = "HuggingFace"
    let charLimit = 500

    var token: String? {
        KeychainHelper.huggingFaceToken
    }

    func isConfigured() -> Bool {
        // HuggingFace отключил анонимный доступ к router-инференсу — без
        // токена запрос всегда падает 401. Проверено вручную: curl без
        // заголовка Authorization получает 401 на router.huggingface.co.
        isTokenConfigured
    }

    var isTokenConfigured: Bool {
        guard let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
        return true
    }

    private func modelId(source: String, target: String) -> String {
        "Helsinki-NLP/opus-mt-\(source.lowercased())-\(target.lowercased())"
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
        guard let url = URL(string: "https://router.huggingface.co/hf-inference/models/\(modelId(source: source, target: target))") else {
            throw TranslationProviderError.badResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }

        let payload: [String: Any] = ["inputs": chunk]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationProviderError.badResponse
        }

        if http.statusCode == 401 {
            throw TranslationProviderError.service("HuggingFace token invalid (401)")
        }
        // Пары без opus-mt модели (например en→ja) — HF отвечает 404 либо
        // "Model not supported by provider" в теле 400/404. Явный сигнал
        // «эта пара не поддерживается», не повод ретраить.
        if http.statusCode == 404 {
            throw TranslationProviderError.notSupported
        }
        // 429 quota — один ретрай с backoff 2с перед тем как сдаться, как для 503
        if http.statusCode == 429 {
            try? await Task.sleep(for: .seconds(2))
            try Task.checkCancellation()
            let (rData, rResp) = try await URLSession.shared.data(for: request)
            if let rHttp = rResp as? HTTPURLResponse, (200...299).contains(rHttp.statusCode) {
                return try decodeResponse(data: rData, http: rHttp)
            }
            throw TranslationProviderError.quotaExceeded
        }
        if http.statusCode == 503 {
            // Модель грузится — пробуем один ретрай через 2с
            try await Task.sleep(for: .seconds(2))
            try Task.checkCancellation()
            let (data2, response2) = try await URLSession.shared.data(for: request)
            guard let http2 = response2 as? HTTPURLResponse, (200...299).contains(http2.statusCode) else {
                throw TranslationProviderError.service("Model is loading, try again shortly")
            }
            return try decodeResponse(data: data2, http: http2)
        }

        return try decodeResponse(data: data, http: http)
    }

    private func decodeResponse(data: Data, http: HTTPURLResponse) throws -> String {
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            if msg.uppercased().contains("LIMIT") || msg.uppercased().contains("QUOTA") {
                throw TranslationProviderError.quotaExceeded
            }
            if msg.contains("not supported by provider") {
                throw TranslationProviderError.notSupported
            }
            throw TranslationProviderError.service(msg)
        }

        // Ответ HF может быть [{"translation_text": "..."}] или {"translation_text": "..."}
        if let arr = try? JSONDecoder().decode([HFResponse].self, from: data),
           let first = arr.first, !first.translationText.isEmpty
        {
            return first.translationText
        }
        if let single = try? JSONDecoder().decode(HFResponse.self, from: data),
           !single.translationText.isEmpty
        {
            return single.translationText
        }
        // Иногда модель возвращает {"generated_text": "..."}
        if let alt = try? JSONDecoder().decode(HFAltResponse.self, from: data),
           let text = alt.generatedText ?? alt.translationText, !text.isEmpty
        {
            return text
        }
        throw TranslationProviderError.badResponse
    }

    private struct HFResponse: Decodable {
        let translationText: String

        enum CodingKeys: String, CodingKey {
            case translationText = "translation_text"
        }
    }

    private struct HFAltResponse: Decodable {
        let generatedText: String?
        let translationText: String?

        enum CodingKeys: String, CodingKey {
            case generatedText = "generated_text"
            case translationText = "translation_text"
        }
    }
}
