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
        var translator = CloudTranslator()
        translator.contactEmail = contactEmail
        return try await translator.translate(text, from: source, to: target)
    }
}
