import Foundation

/// Вспомогательная логика выбора языка перевода.
///
/// Зависит только от Foundation, чтобы прогоняться без сборки приложения —
/// см. `Tools/SelfCheck.swift`.
enum TranslationDirection {
    static func sameLanguage(_ lhs: Locale.Language, _ rhs: Locale.Language) -> Bool {
        lhs.languageCode?.identifier == rhs.languageCode?.identifier
    }

    /// Куда предложить перевести, когда текст уже на целевом языке.
    ///
    /// Автоподмены здесь нет: результат показывается пользователю кнопкой,
    /// а не применяется молча. Порядок предпочтений — язык системы, затем
    /// английский, затем первый подходящий из поддерживаемых.
    /// `nil` означает, что альтернативы нет и предлагать нечего.
    static func suggestedAlternative(
        detected: Locale.Language,
        preferred: Locale.Language?,
        supported: [String]
    ) -> Locale.Language? {
        func isUsable(_ code: String) -> Bool {
            supported.contains(code)
                && !sameLanguage(Locale.Language(identifier: code), detected)
        }

        if let preferredCode = preferred?.languageCode?.identifier, isUsable(preferredCode) {
            return Locale.Language(identifier: preferredCode)
        }
        if isUsable("en") {
            return Locale.Language(identifier: "en")
        }
        return supported.first(where: isUsable).map { Locale.Language(identifier: $0) }
    }
}
