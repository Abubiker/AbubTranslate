import Foundation

// Проверка выбора направления перевода.
// Запуск:
//   swiftc -o /tmp/testdir Sources/Managers/TranslationDirection.swift Tools/TestDirection.swift && /tmp/testdir

func lang(_ code: String) -> Locale.Language {
    Locale.Language(identifier: code)
}

@main
enum TestDirection {
    static func main() {
        let ru = lang("ru")
        let en = lang("en")
        let de = lang("de")

        // Совпал с A → уходим в B.
        precondition(TranslationDirection.resolveTarget(detected: ru, a: ru, b: en) == en)

        // Совпал с B → уходим в A.
        precondition(TranslationDirection.resolveTarget(detected: en, a: ru, b: en) == ru)

        // Третий язык → уходим в A, а не в ошибку.
        precondition(TranslationDirection.resolveTarget(detected: de, a: ru, b: en) == ru)

        // Регион не должен влиять: en-GB это тот же английский.
        precondition(TranslationDirection.resolveTarget(detected: lang("en-GB"), a: ru, b: en) == ru)
        precondition(TranslationDirection.resolveTarget(detected: ru, a: lang("ru-RU"), b: en) == en)

        // Вырожденная пара A == B: направление остаётся определённым.
        precondition(TranslationDirection.resolveTarget(detected: ru, a: ru, b: ru) == ru)

        print("TranslationDirection: OK")
    }
}
