import NaturalLanguage

enum LanguageDetector {
    /// Уверенность, при которой чистому распознаванию доверяем как есть.
    /// Ниже — короткий текст, а на коротком модель гадает между похожими
    /// языками: «Hello» определяет как хорватский, «Привет» как болгарский.
    private static let confidentThreshold = 0.8

    /// Языки, с которых текст копируют чаще всего. Второй заход поднимает
    /// их приоритет и запрещает уходить в длинный хвост редких языков.
    /// Узкий список — специально: `languageHints` на сотнях языков,
    /// наоборот, ломает распознавание целиком (проверено замером).
    private static let commonSourcePriors: [NLLanguage: Double] = {
        var priors: [NLLanguage: Double] = [:]
        for code in ["ru", "en", "uk", "de", "fr", "es", "it", "pt", "zh", "ja", "ko", "ar", "tr", "pl", "nl", "cs"] {
            priors[NLLanguage(rawValue: code)] = (code == "en" || code == "ru") ? 6.0 : 1.0
        }
        priors[.simplifiedChinese] = 1.0
        return priors
    }()

    static func detect(_ text: String) -> Locale.Language? {
        let plain = topHypotheses(text, priors: nil)
        guard let (code, confidence) = plain.first else { return nil }
        if confidence >= confidentThreshold {
            return Locale.Language(identifier: code)
        }
        let hinted = topHypotheses(text, priors: commonSourcePriors)
        return Locale.Language(identifier: hinted.first?.0 ?? code)
    }

    private static func topHypotheses(
        _ text: String,
        priors: [NLLanguage: Double]?
    ) -> [(String, Double)] {
        let recognizer = NLLanguageRecognizer()
        if let priors { recognizer.languageHints = priors }
        recognizer.processString(text)
        return recognizer.__languageHypotheses(withMaximum: 3)
            .map { ($0.key.rawValue, $0.value.doubleValue) }
            .sorted { $0.1 > $1.1 }
    }
}
