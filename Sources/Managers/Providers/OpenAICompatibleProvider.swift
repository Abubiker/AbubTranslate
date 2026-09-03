import Foundation

/// OpenAI-совместимый провайдер — один универсальный LLM для любых пар.
/// Базовый URL, ключ и модель задаются пользователем (Settings → Облако →
/// OpenAI-compatible). Endpoint всегда `{baseURL}/chat/completions` —
/// пользователь вводит только `/v1` часть, нормализация добавляет хвост.
///
/// Промпт фиксирован и зависит от смены языков `from`/`to`, чтобы модель
/// не болтала: возвращает только перевод без кавычек и пояснений.
/// Проверка подключения — короткий `Hello en→ru` запрос, успех 200 или код+текст,
/// с замером времени ответа.
///
/// Задержка LLM-перевода почти всегда не сеть, а reasoning-токены: модели
/// вроде DeepSeek/Qwen думают вслух перед ответом, и content приходит только
/// после всей цепочки размышлений. По умолчанию (`openai_disable_thinking`)
/// запросы гасят thinking полями того семейства модели, которое узнаётся по
/// имени; сервера, отвергающие неизвестные поля (строгий vLLM и т.п.),
/// получают один ретрай без допов на 400 с жалобой на формат тела.
struct OpenAICompatibleProvider: TranslationProvider {
    let id = "openai_compat"
    let name = "OpenAI"
    let charLimit = 3500

    var baseURL: String? { UserDefaults.standard.string(forKey: "openai_base_url") }
    var key: String? { KeychainHelper.openAIKey }
    var model: String? { UserDefaults.standard.string(forKey: "openai_model") }
    /// Выключатели по умолчанию ON — «тихий» дефолт: пользователь, не
    /// заходивший в настройки, получает быстрый перевод, а не диалог
    /// «модель думает 40 секунд».
    var disableThinking: Bool {
        UserDefaults.standard.object(forKey: "openai_disable_thinking") as? Bool ?? true
    }

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

    /// Тестовый запрос для кнопки Проверить — простой Hello en→ru с тем же
    /// телом, что и боевые запросы (thinking-off поля, max_tokens), иначе
    /// замер в тайминге расходился бы с реальным переводом.
    func checkConnection() async throws -> (statusCode: Int, body: String, elapsed: Duration) {
        guard let url = endpointURL() else {
            throw TranslationProviderError.notConfigured(name)
        }
        guard let m = model?.trimmingCharacters(in: .whitespacesAndNewlines), !m.isEmpty else {
            throw TranslationProviderError.notConfigured(name)
        }
        if !isConfigured() { throw TranslationProviderError.notConfigured(name) }

        var body: [String: Any] = [
            "model": m,
            "messages": [
                ["role": "system", "content": systemPrompt(from: "en", to: "ru")],
                ["role": "user", "content": "Hello"],
            ],
        ]
        applyBudgetFields(into: &body, model: m, cap: 64)
        if disableThinking {
            reasoningFields(model: m).forEach { body[$0] = $1 }
        }

        let start = ContinuousClock.now
        let result = try await postChat(url: url, body: body)
        let elapsed = start.duration(to: .now)
        guard (200...299).contains(result.http.statusCode) else {
            throw mapError(status: result.http.statusCode, data: result.data)
        }
        // проверить что choices не пустые
        guard let obj = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
              let choices = obj["choices"] as? [[String: Any]],
              let first = choices.first,
              let msg = first["message"] as? [String: Any],
              let content = msg["content"] as? String,
              !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw TranslationProviderError.badResponse
        }
        let text = String(data: result.data, encoding: .utf8) ?? ""
        return (result.http.statusCode, text, elapsed)
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

        var body: [String: Any] = [
            "model": m,
            "messages": [
                ["role": "system", "content": systemPrompt(from: source, to: target)],
                ["role": "user", "content": chunk],
            ],
        ]
        // Потолок от разрастания ответа: перевод не может быть длиннее
        // источника в разы, а thinking-модель без потолка тратит дельту
        // на размышления вслух. temperature/max_tokens vs
        // max_completion_tokens — по семейству модели в applyBudgetFields.
        applyBudgetFields(into: &body, model: m, cap: min(4096, max(128, chunk.count * 3 + 64)))
        if disableThinking {
            reasoningFields(model: m).forEach { body[$0] = $1 }
        }

        let result = try await postChat(url: url, body: body)
        guard (200...299).contains(result.http.statusCode) else {
            throw mapError(status: result.http.statusCode, data: result.data)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any],
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

    // MARK: - Reasoning-off и пост

    /// Поля выключения размышлений по семейству модели. Денег за незнание
    /// не берём: эвристика по имени, а строгие сервера, для которых лишних
    /// полей не бывает, ловятся ретраем в `postChat`.
    /// `thinking`/`enable_thinking` — диалект DeepSeek/Qwen-совместимых
    /// шлюзов; `reasoning_effort` — OpenAI.
    private func reasoningFields(model: String) -> [String: Any] {
        let lower = model.lowercased()
        let tokens = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        if lower.contains("deepseek") {
            return ["thinking": ["type": "disabled"]]
        }
        if lower.contains("qwen") || lower.contains("glm-4.5") || lower.contains("kimi-k2") {
            return ["enable_thinking": false]
        }
        if lower.contains("gpt-5") || lower.contains("chatgpt-") || tokens.contains("o3") || tokens.contains("o4") {
            return ["reasoning_effort": "none"]
        }
        if tokens.contains("o1") || tokens.contains("o2") {
            // у o1 нет "none" — минимум low
            return ["reasoning_effort": "low"]
        }
        return [:]
    }

    /// OpenAI-серия reasoning-моделей (o1+, gpt-5): у них ДРУГОЙ контракт
    /// лимитов — `max_tokens` отбит 400 «Unsupported parameter», нужен
    /// `max_completion_tokens`, и temperature не-1 тоже 400. Гадание по
    /// имени — тот же компромисс, что и в `reasoningFields`.
    private func isOpenAIReasoning(model: String) -> Bool {
        let lower = model.lowercased()
        let tokens = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        return lower.contains("gpt-5") || lower.contains("chatgpt-")
            || tokens.contains("o1") || tokens.contains("o2")
            || tokens.contains("o3") || tokens.contains("o4")
    }

    /// Ограничители ответа, общие для боевого запроса и проверки.
    private func applyBudgetFields(into body: inout [String: Any], model: String, cap: Int) {
        if isOpenAIReasoning(model: model) {
            body["max_completion_tokens"] = cap
        } else {
            body["temperature"] = 0
            body["max_tokens"] = cap
        }
    }

    private static let reasoningFieldKeys = ["thinking", "enable_thinking", "reasoning_effort"]

    struct ChatResponse {
        let data: Data
        let http: HTTPURLResponse
    }

    /// POST с телом; при 400 с жалобой на неизвестные поля и наличии
    /// reasoning-допов — один ретрай без них (строгий vLLM и подобные).
    private func postChat(url: URL, body: [String: Any]) async throws -> ChatResponse {
        let first = try await postOnce(url: url, body: body)
        let hasExtras = Self.reasoningFieldKeys.contains { body[$0] != nil }
        guard first.http.statusCode == 400, hasExtras, Self.looksLikeUnknownFieldError(first.data) else {
            return first
        }
        var stripped = body
        for key in Self.reasoningFieldKeys { stripped.removeValue(forKey: key) }
        return try await postOnce(url: url, body: stripped)
    }

    private func postOnce(url: URL, body: [String: Any]) async throws -> ChatResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            request.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationProviderError.badResponse }
        return ChatResponse(data: data, http: http)
    }

    private static func looksLikeUnknownFieldError(_ data: Data) -> Bool {
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        let rejected = ["unknown", "unrecognized", "unexpected", "extra", "not a permitted", "unexpected keyword", "invalid"]
        let target = ["field", "parameter", "argument", "keyword", "schema"]
        return rejected.contains { text.contains($0) } && target.contains { text.contains($0) }
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
