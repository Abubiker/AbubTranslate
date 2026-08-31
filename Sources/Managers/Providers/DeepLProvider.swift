import Foundation

/// DeepL API v2 — облачный движок, требует ключ. Сам блокирует запросы с
/// российских IP на уровне сети (не только оплату) — ключ тут не при чём.
/// Пользователь в курсе, решил добавить всё равно — риск и ответственность
/// на нём, тот же принцип, что для остальных облачных движков.
///
/// Контракт подтверждён живым запросом к developers.deepl.com/docs (в
/// отличие от Yandex, эта документация не за CAPTCHA), НЕ живым запросом к
/// самому API — завести DeepL-аккаунт с ключом приложение не может сделать
/// за пользователя.
struct DeepLProvider: TranslationProvider {
    let id = "deepl"
    let name = "DeepL"
    let charLimit = 4000

    var key: String? { KeychainHelper.deepLKey }

    func isConfigured() -> Bool {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return false }
        return true
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translateChunked(text, from: source, to: target) {
            try await self.translateChunk($0, from: source, to: target)
        }
    }

    /// source_lang не требует диалектного варианта (просто "EN", "PT", "ZH").
    /// target_lang для EN/PT/ZH требует вариант, иначе 400 — берём разумный
    /// дефолт (US/европейский португальский/упрощённый китайский).
    private func deepLTargetCode(_ iso: String) -> String {
        switch iso {
        case "en": return "EN-US"
        case "pt": return "PT-PT"
        case "zh": return "ZH-HANS"
        default: return iso.uppercased()
        }
    }

    /// Free-ключ отличается суффиксом ":fx" — у него отдельный хост,
    /// платный на api.deepl.com получит 403 на api-free и наоборот.
    private func host(for key: String) -> String {
        key.hasSuffix(":fx") ? "api-free.deepl.com" : "api.deepl.com"
    }

    /// GET /v2/usage — сколько символов уже потрачено и какой лимит у
    /// текущего ключа. Для free-ключа лимит разовый (см. описание в
    /// EngineMode), не месячный — это решает сам DeepL на своей стороне,
    /// приложение просто показывает то, что вернул сервер, без своих
    /// предположений о тарифе.
    func checkUsage() async throws -> (count: Int, limit: Int) {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else {
            throw TranslationProviderError.notConfigured(name)
        }

        var request = URLRequest(url: URL(string: "https://\(host(for: k))/v2/usage")!)
        request.timeoutInterval = 20
        request.setValue("DeepL-Auth-Key \(k)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationProviderError.badResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }
        guard let decoded = try? JSONDecoder().decode(UsageResponse.self, from: data) else {
            throw TranslationProviderError.badResponse
        }
        return (decoded.character_count, decoded.character_limit)
    }

    private struct UsageResponse: Decodable {
        let character_count: Int
        let character_limit: Int
    }

    private func translateChunk(_ chunk: String, from source: String, to target: String) async throws -> String {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else {
            throw TranslationProviderError.notConfigured(name)
        }

        var request = URLRequest(url: URL(string: "https://\(host(for: k))/v2/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("DeepL-Auth-Key \(k)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "text": [chunk],
            "source_lang": source.uppercased(),
            "target_lang": deepLTargetCode(target),
        ])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationProviderError.badResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }

        guard let decoded = try? JSONDecoder().decode(DeepLResponse.self, from: data),
              let text = decoded.translations.first?.text, !text.isEmpty
        else {
            throw TranslationProviderError.badResponse
        }
        return text
    }

    /// Формат ошибки не проверен живым запросом (нет ключа) — защитная
    /// обработка как у Azure/Google. 456 — специфичный для DeepL код
    /// "квота исчерпана", не общий HTTP-статус.
    private func mapError(status: Int, data: Data) -> TranslationProviderError {
        struct DeepLError: Decodable { let message: String? }
        let decoded = try? JSONDecoder().decode(DeepLError.self, from: data)
        let message = decoded?.message ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"

        if status == 403 {
            return .service("DeepL: \(message)")
        }
        if status == 456 || status == 429 {
            return .quotaExceeded
        }
        if status == 400 {
            return .notSupported
        }
        return .service("DeepL (\(status)): \(message)")
    }

    private struct DeepLResponse: Decodable {
        struct Translation: Decodable { let text: String }
        let translations: [Translation]
    }
}
