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
            reasoningFields(model: m, host: url.host).forEach { body[$0] = $1 }
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
            reasoningFields(model: m, host: url.host).forEach { body[$0] = $1 }
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

    /// Память «этот хост проглотил это поле»: на первый 5xx/жалобу поля
    /// запоминаются (см. postChat), reasoningFields больше их не шлёт —
    /// steady-state один хоп вместо лестницы каждый раз. Чиселенко
    /// «thinking→reasoning_effort:none» для DeepSeek-ветки — частный случай:
    /// при отвергнутом thinking пробуется замена (замер forgetapi: thinking
    /// — 5xx, effort-none — 200 и reasoning_tokens=0).
    private final class DialectMemory: @unchecked Sendable {
        static let shared = DialectMemory()
        private let lock = NSLock()
        private var rejected: [String: Set<String>] = [:]

        func isRejected(_ key: String, host: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            return rejected[host]?.contains(key) ?? false
        }

        func mergeRejected(host: String, keys: Set<String>) {
            guard !keys.isEmpty else { return }
            lock.lock(); rejected[host, default: []].formUnion(keys); lock.unlock()
        }
    }

    /// Поля выключения размышлений по семейству модели. Денег за незнание
    /// не берём: эвристика по имени, а строгие сервера, для которых лишних
    /// полей не бывает, ловятся ретраем в `postChat`.
    /// `thinking`/`enable_thinking` — диалект DeepSeek/Qwen-совместимых
    /// шлюзов; `reasoning_effort` — OpenAI; `reasoning:{effort:none}` —
    /// OpenRouter (имена моделей его не выдают, зато узнаваем адрес).
    private func reasoningFields(model: String, host: String?) -> [String: Any] {
        let lower = model.lowercased()
        let tokens = Set(lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init))
        func allowed(_ key: String) -> Bool {
            guard let host else { return true }
            return !DialectMemory.shared.isRejected(key, host: host)
        }
        var fields: [String: Any] = [:]
        if lower.contains("deepseek") {
            if allowed("thinking") {
                fields["thinking"] = ["type": "disabled"]
            } else if allowed("reasoning_effort") {
                // thinking этим хостом проглочен — пробуем OpenAI-стандарт
                fields["reasoning_effort"] = "none"
            }
        } else if lower.contains("qwen") || lower.contains("glm-4.5") || lower.contains("kimi-k2") {
            if allowed("enable_thinking") { fields["enable_thinking"] = false }
        } else if lower.contains("gpt-5") || lower.contains("chatgpt-") || tokens.contains("o3") || tokens.contains("o4") {
            if allowed("reasoning_effort") { fields["reasoning_effort"] = "none" }
        } else if tokens.contains("o1") || tokens.contains("o2") {
            // у o1 нет "none" — минимум low
            if allowed("reasoning_effort") { fields["reasoning_effort"] = "low" }
        }
        if baseURL?.lowercased().contains("openrouter.ai") == true, allowed("reasoning") {
            // OpenRouter понимает этот диалект для всех моделей, умеющих
            // thinking (список supported_parameters в /api/v1/models).
            fields["reasoning"] = ["effort": "none"]
        }
        return fields
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

    /// Все ключи, которые `reasoningFields` вообще добавляет к телу.
    /// «reasoning» — объект OpenRouter; без него в списке hasExtras врал
    /// для любых openrouter-запросов: strip-ретрай не включался на 400
    /// «Reasoning is mandatory» (minimax-m2.7:free), а «голый» кандидат
    /// уносил dict с собой.
    private static let reasoningFieldKeys = ["thinking", "enable_thinking", "reasoning_effort", "reasoning"]

    struct ChatResponse {
        let data: Data
        let http: HTTPURLResponse
    }

    /// POST с телом-лесенкой: family-диалект → (если был `thinking`)
    /// OpenAI-стандартный `reasoning_effort:none` → голое тело. Первый
    /// же ответ <500 (в т.ч. честные 4xx валидации, которые mapError
    /// разберёт наверху) прекращает лестницу; 5xx и 400 с жалобой на
    /// поля — сигнал «тело ядовитое для этого шлюза», следующий кандидат.
    /// Замеры: forgetapi на `thinking` — 502 за 90мс, на `reasoning_effort`
    /// — 200; голая заявка без всех допов теряла бы шанс выключить
    /// thinking, поэтому effort идёт до stripped-bare, а не после.
    private func postChat(url: URL, body: [String: Any]) async throws -> ChatResponse {
        var candidates: [[String: Any]] = [body]
        let hasExtras = Self.reasoningFieldKeys.contains { body[$0] != nil }
        if hasExtras {
            if body["thinking"] != nil, !body.keys.contains("reasoning_effort") {
                var effort = body
                for key in Self.reasoningFieldKeys { effort.removeValue(forKey: key) }
                effort["reasoning_effort"] = "none"
                candidates.append(effort)
            }
            var bare = body
            for key in Self.reasoningFieldKeys { bare.removeValue(forKey: key) }
            candidates.append(bare)
        }

        var last: ChatResponse?
        for (i, candidate) in candidates.enumerated() {
            let result = try await postOnce(url: url, body: candidate)
            let status = result.http.statusCode
            let poison = (500...599).contains(status)
                || (status == 400 && Self.looksLikeUnknownFieldError(result.data))
            guard poison else {
                if i > 0, let host = url.host {
                    // Победитель лестницы не содержит ключей, которые были
                    // в отравленном оригинале, — значит хост не переваривает
                    // именно их: записываем в память, reasoningFields
                    // перестанет их строить. Отклонённый effort-заменитель
                    // тоже попадает в множество → ветка сама деградирует до
                    // пустого набора, осцилляции mark/clear больше нет.
                    let dropped = Self.reasoningFieldKeys.filter {
                        body[$0] != nil && candidate[$0] == nil
                    }
                    DialectMemory.shared.mergeRejected(host: host, keys: Set(dropped))
                }
                return result
            }
            last = result
        }
        return last!
    }

    private func postOnce(url: URL, body: [String: Any]) async throws -> ChatResponse {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        // 45, а не 20: LLM с незакрытым thinking отвечает дольше порога, и
        // прошлый 20-секундный таймаут резал живой перевод на корню —
        // URLError(.timedOut) считался транзиентным, три ретрая сжигали
        // минуту и провал были бы тихим откатом на MyMemory.
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            request.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationProviderError.badResponse }
        return ChatResponse(data: data, http: http)
    }

    // MARK: - Диагностика (`--openai-latency`)

    /// Результат одного зондового запроса с произвольным текстом и
    /// полями. Боевые лимиты (max_tokens/temperature) шлются как в
    /// translateChunk — замер того, что реально испытывает пользователь;
    /// у thinking-моделей с урезанным бюджетом content может прийти
    /// пустым при reasoning_tokens > 0 — это тоже ответ на вопрос
    /// «думает ли модель».
    struct ProbeResult {
        let status: Int
        let elapsed: Duration
        let completionTokens: Int
        let reasoningTokens: Int
        let hasReasoning: Bool
        let snippet: String
        let contentChars: Int
        let finishReason: String
        let error: String?
    }

    /// Зондовый запрос для `--openai-latency`. `fields == nil` — боевое
    /// тело (budget + family-диалект), иначе — явно указанные поля вместо
    /// диалекта: матрица «кто из агрегаторов что режет». `ladder == true`
    /// — через боевой `postChat` со strip-ретраем, т.е. ровно то, что
    /// испытывает пользователь; матрица диалектов ходит намеренно наго.
    func probe(
        text: String,
        fields: [String: Any]? = nil,
        modelOverride: String? = nil,
        ladder: Bool = false
    ) async -> ProbeResult {
        let m = (modelOverride?.trimmingCharacters(in: .whitespacesAndNewlines))
            .flatMap { $0.isEmpty ? nil : $0 }
            ?? model?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = endpointURL(), let m, !m.isEmpty, isConfigured() else {
            return ProbeResult(status: -1, elapsed: .zero, completionTokens: 0,
                               reasoningTokens: 0, hasReasoning: false, snippet: "", contentChars: 0, finishReason: "", error: "not configured")
        }
        var body: [String: Any] = [
            "model": m,
            "messages": [
                ["role": "system", "content": systemPrompt(from: "en", to: "ru")],
                ["role": "user", "content": text],
            ],
        ]
        applyBudgetFields(into: &body, model: m, cap: min(4096, max(128, text.count * 3 + 64)))
        let effective = fields ?? (disableThinking ? reasoningFields(model: m, host: url.host) : [:])
        for (k, v) in effective { body[k] = v }

        let start = ContinuousClock.now
        do {
            let result = try await (ladder
                ? postChat(url: url, body: body)
                : postOnce(url: url, body: body))
            let elapsed = start.duration(to: .now)
            guard (200...299).contains(result.http.statusCode) else {
                return ProbeResult(
                    status: result.http.statusCode, elapsed: elapsed,
                    completionTokens: 0, reasoningTokens: 0, hasReasoning: false,
                    snippet: "", contentChars: 0, finishReason: "", error: String(data: result.data, encoding: .utf8)
                )
            }
            let obj = try? JSONSerialization.jsonObject(with: result.data) as? [String: Any]
            let choices = obj?["choices"] as? [[String: Any]]
            let msg = choices?.first?["message"] as? [String: Any]
            let content = (msg?["content"] as? String) ?? ""
            let hasReasoning = !((msg?["reasoning_content"] as? String) ?? "").isEmpty
            let finish = (choices?.first?["finish_reason"] as? String) ?? "?"
            let usage = obj?["usage"] as? [String: Any]
            let details = usage?["completion_tokens_details"] as? [String: Any]
            return ProbeResult(
                status: result.http.statusCode,
                elapsed: elapsed,
                completionTokens: usage?["completion_tokens"] as? Int ?? 0,
                reasoningTokens: details?["reasoning_tokens"] as? Int ?? 0,
                hasReasoning: hasReasoning,
                snippet: String(content.prefix(40)),
                contentChars: content.count,
                finishReason: finish,
                error: nil
            )
        } catch {
            return ProbeResult(status: -1, elapsed: start.duration(to: .now), completionTokens: 0,
                               reasoningTokens: 0, hasReasoning: false, snippet: "", contentChars: 0, finishReason: "",
                               error: error.localizedDescription)
        }
    }

    /// GET {base}/models — каталог проксирует почти все реализации;
    /// имена нужны, чтобы искать non-thinking-близнецев модели.
    func listModelIDs() async -> [String] {
        guard let endpointBase = endpointURL() else { return [] }
        var endpoint = endpointBase.absoluteString
        guard endpoint.hasSuffix("/chat/completions") else { return [] }
        endpoint.removeLast("/chat/completions".count)
        guard let url = URL(string: endpoint + "/models") else { return [] }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        if let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            request.setValue("Bearer \(k)", forHTTPHeaderField: "Authorization")
        }
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let arr = obj["data"] as? [[String: Any]]
        else { return [] }
        return arr.compactMap { $0["id"] as? String }
    }

    private static func looksLikeUnknownFieldError(_ data: Data) -> Bool {
        let text = String(data: data, encoding: .utf8)?.lowercased() ?? ""
        // Явный случай из замера на OpenRouter: модели с обязательным
        // reasoning (minimax-m2.7:free) отвечают 400 «Reasoning is
        // mandatory … and cannot be disabled» — это тоже сигнал «убери
        // наши дополнения и повтори», а не конец света.
        if text.contains("mandatory") { return true }
        let rejected = ["unknown", "unrecognized", "unexpected", "extra", "not a permitted", "unexpected keyword", "invalid"]
        let target = ["field", "parameter", "argument", "keyword", "schema"]
        return rejected.contains { text.contains($0) } && target.contains { text.contains($0) }
    }

    private func mapError(status: Int, data: Data) -> TranslationProviderError {
        let text = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
        // попытаться достать message из OpenAI error
        // 429 — не всегда «квота кончилась»: у агрегаторов это по-минутный
        // RPM-лимит, переждиваемый бэк-оффом (ChunkRetry.rateLimitBackoff),
        // метка (429) в тексте служит признаком ретрая, наружу идёт
        // настоящее сообщение прокси вместо вранья про дневную квоту.
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let err = obj["error"] as? [String: Any],
           let msg = err["message"] as? String {
            return .service("OpenAI (\(status)): \(msg)")
        }
        return .service("OpenAI (\(status)): \(text)")
    }
}
