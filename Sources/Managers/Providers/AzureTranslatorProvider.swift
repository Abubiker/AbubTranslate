import Foundation

/// Azure AI Translator — облачный движок, требует ключ подписки (регион
/// нужен только для регионального ресурса; для global single-service
/// ресурса необязателен).
///
/// Контракт подтверждён официальной документацией Microsoft, НЕ живым
/// запросом: создание Azure-аккаунта требует карту, это действие приложение
/// не может выполнить за пользователя (см. правила: не заводить аккаунты,
/// не вводить платёжные данные). В отличие от HuggingFace/MyMemory, этот
/// провайдер не проверен curl с реальным ключом — только по спецификации:
/// learn.microsoft.com/azure/ai-services/translator/text-translation/quickstart/rest-api
/// learn.microsoft.com/azure/ai-services/translator/text-translation/reference/status-response-codes
struct AzureTranslatorProvider: TranslationProvider {
    let id = "azure"
    let name = "Azure Translator"
    /// Азуровский лимит — 50 000 символов и 10 000 элементов массива на
    /// запрос суммарно; берём один элемент на чанк с большим запасом.
    let charLimit = 4000

    var key: String? { KeychainHelper.azureKey }
    var region: String? { KeychainHelper.azureRegion }

    func isConfigured() -> Bool {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else { return false }
        return true
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        try await translateChunked(text, from: source, to: target) {
            try await self.translateChunk($0, from: source, to: target)
        }
    }

    /// У Azure нет короткого кода "zh" — только zh-Hans/zh-Hant. Остальные
    /// коды в языковых списках приложения совпадают с азуровскими один в один.
    private func azureCode(_ iso: String) -> String {
        iso == "zh" ? "zh-Hans" : iso
    }

    private func translateChunk(_ chunk: String, from source: String, to target: String) async throws -> String {
        guard let k = key?.trimmingCharacters(in: .whitespacesAndNewlines), !k.isEmpty else {
            throw TranslationProviderError.notConfigured(name)
        }

        var components = URLComponents(string: "https://api.cognitive.microsofttranslator.com/translate")!
        components.queryItems = [
            URLQueryItem(name: "api-version", value: "3.0"),
            URLQueryItem(name: "from", value: azureCode(source)),
            URLQueryItem(name: "to", value: azureCode(target)),
        ]

        var request = URLRequest(url: components.url!)
        request.httpMethod = "POST"
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(k, forHTTPHeaderField: "Ocp-Apim-Subscription-Key")
        if let r = region?.trimmingCharacters(in: .whitespacesAndNewlines), !r.isEmpty {
            request.setValue(r, forHTTPHeaderField: "Ocp-Apim-Subscription-Region")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [["Text": chunk]])

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationProviderError.badResponse
        }

        guard (200...299).contains(http.statusCode) else {
            throw mapError(status: http.statusCode, data: data)
        }

        guard let arr = try? JSONDecoder().decode([AzureResponse].self, from: data),
              let text = arr.first?.translations.first?.text, !text.isEmpty
        else {
            throw TranslationProviderError.badResponse
        }
        return text
    }

    /// Формат ошибки: {"error":{"code":401000,"message":"..."}}.
    /// Код 400036 — неподдерживаемый язык, honest notSupported вместо
    /// общей service-ошибки, чтобы цепочка ушла в MyMemory, а не ретраила.
    private func mapError(status: Int, data: Data) -> TranslationProviderError {
        struct AzureError: Decodable {
            struct Inner: Decodable { let code: Int; let message: String }
            let error: Inner
        }
        let decoded = try? JSONDecoder().decode(AzureError.self, from: data)
        let code = decoded?.error.code
        let message = decoded?.error.message ?? String(data: data, encoding: .utf8) ?? "HTTP \(status)"

        if status == 401 || status == 403 {
            return .service("Azure: \(message)")
        }
        if status == 429 {
            // Считаем true-quota только явные упоминания квоты; голый 429 у
            // Azure — это поминутный SFR, переждиваемый бэк-оффом (метка
            // (429) для ChunkRetry).
            if message.lowercased().contains("quota") || message.lowercased().contains("budget") {
                return .quotaExceeded
            }
            return .service("Azure (429): \(message)")
        }
        if status == 400, let code, code == 400036 || code == 400018 {
            return .notSupported
        }
        return .service("Azure (\(code.map(String.init) ?? "\(status)")): \(message)")
    }

    private struct AzureResponse: Decodable {
        struct Translation: Decodable { let text: String }
        let translations: [Translation]
    }
}
