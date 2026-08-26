import Foundation

/// Выбор направления перевода для языковой пары A/B.
///
/// Вынесено отдельно и зависит только от Foundation, чтобы логику можно было
/// прогнать без сборки всего приложения — см. `Tools/TestDirection.swift`.
enum TranslationDirection {
    static func sameLanguage(_ lhs: Locale.Language, _ rhs: Locale.Language) -> Bool {
        lhs.languageCode?.identifier == rhs.languageCode?.identifier
    }

    /// Куда переводить текст на языке `detected`.
    ///
    /// Язык из пары уходит во второй язык пары. Третий язык — в тот из пары,
    /// на котором говорит пользователь (`preferred`, обычно язык системы):
    /// финский при паре en/ru должен становиться русским у русскоязычного и
    /// английским у англоязычного, а не зависеть от того, какая пилюля в
    /// интерфейсе оказалась первой.
    ///
    /// Направление определено всегда, поэтому «текст уже на целевом языке»
    /// перестаёт быть ошибкой.
    static func resolveTarget(
        detected: Locale.Language,
        a: Locale.Language,
        b: Locale.Language,
        preferred: Locale.Language? = nil
    ) -> Locale.Language {
        if sameLanguage(detected, a) { return b }
        if sameLanguage(detected, b) { return a }
        if let preferred {
            if sameLanguage(preferred, a) { return a }
            if sameLanguage(preferred, b) { return b }
        }
        return a
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
        b: Locale.Language,
        preferred: Locale.Language? = nil
    ) -> [Locale.Language] {
        let primary = resolveTarget(detected: detected, a: a, b: b, preferred: preferred)
        let alternate = sameLanguage(primary, a) ? b : a
        var result = [primary]
        if !sameLanguage(alternate, primary), !sameLanguage(alternate, detected) {
            result.append(alternate)
        }
        return result.filter { !sameLanguage($0, detected) }
    }
}
