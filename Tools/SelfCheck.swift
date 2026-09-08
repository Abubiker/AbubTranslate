import Foundation

// Проверка чистой логики: подсказка альтернативного языка, нарезка текста,
// сравнение версий. Гоняется автоматически из Scripts/build.sh перед сборкой.
// Вручную:
//   swiftc -o /tmp/selfcheck Sources/Managers/TranslationDirection.swift \
//       Sources/Managers/TextChunker.swift Sources/Managers/VersionCompare.swift \
//       Tools/SelfCheck.swift && /tmp/selfcheck

func lang(_ code: String) -> Locale.Language {
    Locale.Language(identifier: code)
}

@main
enum SelfCheck {
    static func main() {
        checkDirection()
        checkChunker()
        checkVersions()
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

    static func checkVersions() {
        func newer(_ candidate: String, _ current: String) -> Bool {
            VersionCompare.isNewer(candidate: candidate, than: current)
        }

        // Обычный порядок.
        precondition(newer("1.2", "1.1"))
        precondition(!newer("1.1", "1.1"))
        precondition(!newer("1.0", "1.1"))
        precondition(newer("2.0", "1.9"))
        precondition(newer("1.1", "0"))

        // Числами, а не строками: "10" больше "9".
        precondition(newer("1.10", "1.9"))
        precondition(newer("1.1.10", "1.1.9"))

        // Недостающие компоненты — нули, а не «меньше».
        precondition(!newer("1.1", "1.1.0"))
        precondition(newer("1.1.1", "1.1"))

        // Тег с "v" приходит из GitHub как есть.
        precondition(newer("v1.2", "1.1"))
        precondition(!newer("v1.1", "1.1"))

        // Пре-релиз не новее релиза, из которого вышел: цифры хвоста не
        // должны становиться лишним компонентом версии.
        precondition(!newer("1.1.3-beta2", "1.1.3"))
        precondition(!newer("1.1.3-rc1", "1.1.3"))
        precondition(!newer("1.1.3+build9", "1.1.3"))
        // Но больший номер остаётся большим и с хвостом.
        precondition(newer("1.1.4-beta1", "1.1.3"))

        // Мусор не роняет и не выдумывает обновление.
        precondition(!newer("", "1.1.3"))
        precondition(!newer("не версия", "1.1.3"))

        print("VersionCompare: OK")
    }
}
