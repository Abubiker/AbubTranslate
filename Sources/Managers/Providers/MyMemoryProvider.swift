import Foundation

/// MyMemory — бесплатный fallback без ключа.
/// Вынесено из CloudTranslator.swift, теперь реализует TranslationProvider.
struct MyMemoryProvider: TranslationProvider {
    let id = "mymemory"
    let name = "MyMemory"
    let charLimit = 480

    /// Почта для повышения лимита с 5k до 50k слов/сутки.
    var contactEmail: String?

    func isConfigured() -> Bool { true }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        var configured = CloudTranslator()
        configured.contactEmail = contactEmail
        // let-копия: @Sendable-замыкание параллельных чанков не может
        // захватывать mutable var.
        let translator = configured
        return try await translateChunked(text, from: source, to: target) {
            try await translator.translate($0, from: source, to: target)
        }
    }
}
