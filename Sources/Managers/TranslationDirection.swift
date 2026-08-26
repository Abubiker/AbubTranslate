import Foundation

/// Выбор направления перевода для языковой пары A/B.
///
/// Вынесено отдельно и зависит только от Foundation, чтобы логику можно было
/// прогнать без сборки всего приложения — см. `Tools/TestDirection.swift`.
enum TranslationDirection {
    static func sameLanguage(_ lhs: Locale.Language, _ rhs: Locale.Language) -> Bool {
        lhs.languageCode?.identifier == rhs.languageCode?.identifier
    }

    /// Текст на языке `detected` переводим в B, если он совпал с A,
    /// и в A во всех остальных случаях.
    ///
    /// Из-за этого правила «текст уже на целевом языке» перестаёт быть
    /// ошибкой: направление всегда определено.
    static func resolveTarget(
        detected: Locale.Language,
        a: Locale.Language,
        b: Locale.Language
    ) -> Locale.Language {
        sameLanguage(detected, a) ? b : a
    }

    /// Куда пробовать переводить, в порядке предпочтения.
    ///
    /// Основное направление первым, вторым — оставшийся язык пары. Нужно для
    /// случая «определился третий язык, а движок не умеет переводить его в A,
    /// но умеет в B»: без отката получался бы отказ на ровном месте.
    /// Совпадающие и вырожденные варианты отбрасываются.
    static func targetCandidates(
        detected: Locale.Language,
        a: Locale.Language,
        b: Locale.Language
    ) -> [Locale.Language] {
        let primary = resolveTarget(detected: detected, a: a, b: b)
        let alternate = sameLanguage(primary, a) ? b : a
        var result = [primary]
        if !sameLanguage(alternate, primary), !sameLanguage(alternate, detected) {
            result.append(alternate)
        }
        return result.filter { !sameLanguage($0, detected) }
    }
}
