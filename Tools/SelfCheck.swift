import Foundation

// Проверка чистой логики: выбор направления перевода и нарезка текста.
// Запуск:
//   swiftc -o /tmp/selfcheck Sources/Managers/TranslationDirection.swift \
//       Sources/Managers/TextChunker.swift Tools/SelfCheck.swift && /tmp/selfcheck

func lang(_ code: String) -> Locale.Language {
    Locale.Language(identifier: code)
}

@main
enum SelfCheck {
    static func main() {
        let ru = lang("ru")
        let en = lang("en")
        let de = lang("de")

        // Совпал с A → уходим в B.
        precondition(TranslationDirection.resolveTarget(detected: ru, a: ru, b: en) == en)

        // Совпал с B → уходим в A.
        precondition(TranslationDirection.resolveTarget(detected: en, a: ru, b: en) == ru)

        // Третий язык без подсказки → уходим в A, а не в ошибку.
        precondition(TranslationDirection.resolveTarget(detected: de, a: ru, b: en) == ru)

        // Третий язык с подсказкой → в язык пользователя, а не в первый по счёту.
        let fi = lang("fi")
        precondition(TranslationDirection.resolveTarget(detected: fi, a: en, b: ru, preferred: ru) == ru)
        precondition(TranslationDirection.resolveTarget(detected: fi, a: ru, b: en, preferred: ru) == ru)
        precondition(TranslationDirection.resolveTarget(detected: fi, a: en, b: ru, preferred: en) == en)

        // Подсказка не из пары ничего не ломает.
        precondition(TranslationDirection.resolveTarget(detected: fi, a: en, b: ru, preferred: de) == en)

        // Подсказка не должна перебивать язык из самой пары.
        precondition(TranslationDirection.resolveTarget(detected: ru, a: ru, b: en, preferred: ru) == en)
        precondition(TranslationDirection.resolveTarget(detected: en, a: en, b: ru, preferred: en) == ru)

        // Кандидаты: сначала предпочтительный, вторым — оставшийся.
        precondition(TranslationDirection.targetCandidates(detected: fi, a: en, b: ru, preferred: ru) == [ru, en])

        // Регион не должен влиять: en-GB это тот же английский.
        precondition(TranslationDirection.resolveTarget(detected: lang("en-GB"), a: ru, b: en) == ru)
        precondition(TranslationDirection.resolveTarget(detected: ru, a: lang("ru-RU"), b: en) == en)

        // Вырожденная пара A == B: направление остаётся определённым.
        precondition(TranslationDirection.resolveTarget(detected: ru, a: ru, b: ru) == ru)

        // Кандидаты: основное направление первым, затем второй язык пары.
        precondition(TranslationDirection.targetCandidates(detected: de, a: ru, b: en) == [ru, en])
        precondition(TranslationDirection.targetCandidates(detected: ru, a: ru, b: en) == [en])
        precondition(TranslationDirection.targetCandidates(detected: en, a: ru, b: en) == [ru])

        // Язык оригинала не должен попасть в кандидаты ни при каком раскладе.
        precondition(TranslationDirection.targetCandidates(detected: ru, a: ru, b: ru).isEmpty)
        precondition(!TranslationDirection.targetCandidates(detected: lang("en-US"), a: ru, b: en).contains(en))

        checkChunker()
        print("TranslationDirection: OK")
    }

    static func checkChunker() {
        // Короткий текст не режется.
        precondition(TextChunker.chunks("Hello there.", limit: 480) == ["Hello there."])

        // Пустой и пробельный вход не даёт пустых кусков.
        precondition(TextChunker.chunks("").isEmpty)
        precondition(TextChunker.chunks("   \n  ").isEmpty)

        // Режется по предложениям, каждый кусок в пределах лимита.
        let sentence = "Minun nimeni on Ella ja olen kahdeksantoista vuotias. "
        let long = String(repeating: sentence, count: 12)
        let parts = TextChunker.chunks(long, limit: 100)
        precondition(parts.count > 1)
        precondition(parts.allSatisfy { $0.count <= 100 })
        precondition(parts.allSatisfy { !$0.isEmpty })

        // Ничего не потеряно: слова сохраняются целиком и в прежнем порядке.
        precondition(parts.joined(separator: " ").split(separator: " ").count
            == long.split(separator: " ").count)

        // Слово длиннее лимита рвётся, а не выбрасывается.
        let huge = String(repeating: "a", count: 250)
        let hugeParts = TextChunker.chunks(huge, limit: 100)
        precondition(hugeParts.count == 3)
        precondition(hugeParts.joined() == huge)

        // Вырожденный лимит не уводит в бесконечный цикл.
        precondition(TextChunker.chunks("abc", limit: 0).isEmpty)

        print("TextChunker: OK")
    }
}
