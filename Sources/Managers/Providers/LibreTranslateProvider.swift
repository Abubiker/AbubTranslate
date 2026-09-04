import Foundation

/// LibreTranslate — открытый API поверх Argos Translate. Пользователь вводит
/// URL своего инстанса (пусто = публичный libretranslate.com, где с ключа
/// portal.libretranslate.com берут и бесплатный тариф); self-hosted инстансы
/// работают вообще без ключа — он опционален.
///
/// Контракт подтверждён официальной документацией docs.libretranslate.com
/// (POST {base}/translate с полями q/source/target/format/api_key, ответ
/// {"translatedText": ...}, ошибка {"error": ...}), живым запросом к
/// публичному инстансу не проверен — тот с 2025 требует ключ у всех.
struct LibreTranslateProvider: TranslationProvider {
    let id = "libretranslate"
    let name = "LibreTranslate"
    /// Консервативно: дефолтный `--char-limit` инстансов 10k, у облачных
    /// тарифов меньше — лучше лишний чанк, чем 400 на границе.
    let charLimit = 4000

    var baseURL: String? { UserDefaults.standard.string(forKey: "libretranslate_base_url") }
    var key: String? { KeychainHelper.libreTranslateKey }

    /// Ключ не обязателен: self-hosted инстансы его не знают. Настроенным
    /// считаем наличие URL (пустой URL = публичный инстанс по умолчанию).
    func isConfigured() -> Bool { true }

    var effectiveBaseURL: String {
        let raw = (baseURL ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        var base = raw.isEmpty ? "https://libretranslate.com" : raw
        if !base.contains("://") { base = "https://" + base }
        while base.hasSuffix("/") { base.removeLast() }
        return base
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translateChunked(text, from: source, to: target) {
            try await self.translateChunk($0, from: source, to: target)
        }
    }

    private func translateChunk(_ chunk: String, from source: String, to target: String) async throws -> String {
        var request = URLRequest(url: URL(string: effectiveBaseURL + "/translate")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        // Ключ — полем тела: поддерживают и облачный шлюз, и self-hosted с
        // --api-keys; Bearer-заголовок понимает только облако.
        var body: [String: Any] = [
            "q": chunk,
            "source": source,
            "target": target,
            "format": "text",
        ]
        if let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty {
            body["api_key"] = k
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw TranslationProviderError.badResponse }
        guard (200...299).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }

        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let text = obj["translatedText"] as? String, !text.isEmpty
        else {
            throw TranslationProviderError.badResponse
        }
        return text
    }

    /// Ошибки инстанса: {"error": "..."} или {"error": {"message":...,"code":n}}.
    private func mapError(status: Int, data: Data) -> TranslationProviderError {
        let message: String
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let raw = obj["error"] {
            if let s = raw as? String {
                message = s
            } else if let dict = raw as? [String: Any], let s = dict["message"] as? String {
                message = s
            } else {
                message = "HTTP \(status)"
            }
        } else {
            message = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
        }

        switch status {
        case 429:
            // RPM-окно инстанса переждивается бэк-оффом (метка (429))
            return .service("LibreTranslate (429): \(message)")
        case 401, 403:
            // Без ключа на облачном инстансе — типичная первопричина; это
            // конфигурация, а не временный сбой: сразу в фолбэк MyMemory.
            return .service("LibreTranslate (\(status)): \(message)")
        case 400:
            let lower = message.lowercased()
            if lower.contains("not supported") || lower.contains("language") {
                return .notSupported
            }
            return .service("LibreTranslate (400): \(message)")
        default:
            return .service("LibreTranslate (\(status)): \(message)")
        }
    }
}
