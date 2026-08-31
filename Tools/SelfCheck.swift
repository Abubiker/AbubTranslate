import Foundation

// Проверка чистой логики: подсказка альтернативного языка и нарезка текста.
// Запуск:
//   swiftc -o /tmp/selfcheck Sources/Managers/TranslationDirection.swift \
//       Sources/Managers/TextChunker.swift Tools/SelfCheck.swift && /tmp/selfcheck

func lang(_ code: String) -> Locale.Language {
    Locale.Language(identifier: code)
}

@main
enum SelfCheck {
    static func main() {
        checkDirection()
        checkChunker()
    }

    static func checkDirection() {
        let all = ["ru", "en", "de", "fr"]

        // Язык системы выигрывает, если он не совпадает с оригиналом.
        precondition(TranslationDirection.suggestedAlternative(
            detected: lang("en"), preferred: lang("ru"), supported: all) == lang("ru"))

        // Совпал с оригиналом — уходим в английский.
        precondition(TranslationDirection.suggestedAlternative(
            detected: lang("ru"), preferred: lang("ru"), supported: all) == lang("en"))

        // Нет подсказки — тоже английский.
        precondition(TranslationDirection.suggestedAlternative(
            detected: lang("de"), preferred: nil, supported: all) == lang("en"))

        // Английский сам оригинал и подсказки нет — берём первый подходящий.
        precondition(TranslationDirection.suggestedAlternative(
            detected: lang("en"), preferred: nil, supported: all) == lang("ru"))

        // Регион не должен влиять: en-GB это тот же английский.
        precondition(TranslationDirection.suggestedAlternative(
            detected: lang("en-GB"), preferred: lang("en-US"), supported: all) == lang("ru"))

        // Поддерживается только язык оригинала — предлагать нечего.
        precondition(TranslationDirection.suggestedAlternative(
            detected: lang("ru"), preferred: lang("ru"), supported: ["ru"]) == nil)

        // Пустой список поддержки не роняет и не выдумывает язык.
        precondition(TranslationDirection.suggestedAlternative(
            detected: lang("ru"), preferred: nil, supported: []) == nil)

        print("TranslationDirection: OK")
    }

    static func checkChunker() {
        precondition(TextChunker.chunks("Hello there.", limit: 480) == ["Hello there."])
        precondition(TextChunker.chunks("").isEmpty)
        precondition(TextChunker.chunks("   \n  ").isEmpty)

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
