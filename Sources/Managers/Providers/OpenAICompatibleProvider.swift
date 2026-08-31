import Foundation

/// OpenAI-совместимый провайдер — один универсальный LLM для любых пар.
/// Базовый URL, ключ и модель задаются пользователем (Settings → Облако →
/// OpenAI-compatible). Endpoint всегда `{baseURL}/chat/completions` —
/// пользователь вводит только `/v1` часть, нормализация добавляет хвост.
///
/// Промпт фиксирован и зависит от смены языков `from`/`to`, чтобы модель
/// не болтала: возвращает только перевод без кавычек и пояснений.
/// Проверка подключения — короткий `Hello en→ru` запрос, успех 200 или код+текст.
struct OpenAICompatibleProvider: TranslationProvider {
    let id = "openai_compat"
    let name = "OpenAI"
    let charLimit = 3500

    var baseURL: String? { UserDefaults.standard.string(forKey: "openai_base_url") }
    var key: String? { KeychainHelper.openAIKey }
    var model: String? { UserDefaults.standard.string(forKey: "openai_model") }

    func isConfigured() -> Bool {
        guard let b = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty,
              let m = model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty
        else { return false }
        // ключ может быть пустым для локальных LLM (ollama) — если host localhost, пропускаем
        if isLocalHost(b) { return true }
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return false }
        return true
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translateChunked(text, from: source, to: target) {
            try await self.translateChunk($0, from: source, to: target)
        }
    }

    /// Тестовый запрос для кнопки Проверить — простой Hello en→ru.
    /// Возвращает статус и тело, успех только при 200 + непустой choices.
    func checkConnection() async throws -> (statusCode: Int, body: String) {
        guard let url = endpointURL() else {
            throw TranslationProviderError.notConfigured(name)
        }
        guard let m = model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else {
            throw TranslationProviderError.notConfigured(name)
        }
        if !isConfigured() { throw TranslationProviderError.notConfigured(name) }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            request.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = [
            "model": m,
            "messages": [
                ["role": "system", "content": systemPrompt(from: "en", to: "ru")],
                ["role": "user", "content": "Hello"],
            ],
            "temperature": 0,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationProviderError.badResponse }
        let text = String(data: data, encoding: .utf8) ?? ""
        guard (200...299).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }
        // проверить что choices не пустые
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TranslationProviderError.badResponse
        }
        return (http.statusCode, text)
    }

    // MARK: - Private

    private func endpointURL() -> URL? {
        guard var b = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines), !b.isEmpty else { return nil }
        while b.hasSuffix("/") { b.removeLast() }
        if b.hasSuffix("/chat/completions") {
            return URL(string: b)
        }
        if b.hasSuffix("/v1") {
            return URL(string: b + "/chat/completions")
        }
        // если содержит /v1 где-то но не в конце — оставим как есть + /chat/completions
        if b.contains("/v1") {
            return URL(string: b + "/chat/completions")
        }
        return URL(string: b + "/v1/chat/completions")
    }

    private func isLocalHost(_ url: String) -> Bool {
        let lower = url.lowercased()
        return lower.contains("localhost") || lower.contains("127.0.0.1") || lower.contains("::1")
    }

    private func systemPrompt(from source: String, to target: String) -> String {
        // Имена языков для человечности, коды для точности — оба меняются при смене языков
        let sourceName = Locale(identifier: "en").localizedString(forLanguageCode: source)?.capitalized ?? source
        let targetName = Locale(identifier: "en").localizedString(forLanguageCode: target)?.capitalized ?? target
        return "You are a professional translator. Translate the following text from \(sourceName) (\(source)) to \(targetName) (\(target)). Output ONLY the translation, no explanations, no quotes, no preamble, no extra text."
    }

    private func translateChunk(_ chunk: String, from source: String, to target: String) async throws -> String {
        guard let url = endpointURL() else {
            throw TranslationProviderError.notConfigured(name)
        }
        guard let m = model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else {
            throw TranslationProviderError.notConfigured(name)
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            request.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }

        let body: [String: Any] = [
            "model": m,
            "messages": [
                ["role": "system", "content": systemPrompt(from: source, to: target)],
                ["role": "user", "content": chunk],
            ],
            "temperature": 0,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationProviderError.badResponse }

        guard (200...299).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String
        else {
            throw TranslationProviderError.badResponse
        }
        var trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        // убрать обрамляющие кавычки если модель их добавила
        if (trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")) || (trimmed.hasPrefix("'") && trimmed.hasSuffix("'")) {
            trimmed = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard !trimmed.isEmpty else { throw TranslationProviderError.badResponse }
        return trimmed
    }

    private func mapError(status: Int, data: Data) -> TranslationProviderError {
        let text = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
        // попытаться достать message из OpenAI error
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            if status == 401 || status == 403 {
                return .service("OpenAI (\(status)): \(msg)")
            }
            if status == 429 { return .quotaExceeded }
            return .service("OpenAI (\(status)): \(msg)")
        }
        if status == 401 || status == 403 { return .service("OpenAI (\(status)): \(text)") }
        if status == 429 { return .quotaExceeded }
        if status == 400 { return .service("OpenAI (\(status)): \(text)") }
        return .service("OpenAI (\(status)): \(text)")
    }
}
