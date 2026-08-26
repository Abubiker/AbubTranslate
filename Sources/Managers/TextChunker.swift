import Foundation

/// Нарезка текста на куски под лимит запроса облачного переводчика.
///
/// Зависит только от Foundation — логику можно прогнать без сборки приложения,
/// см. `Tools/SelfCheck.swift`.
enum TextChunker {
    /// MyMemory отвечает 403 на запрос длиннее 500 символов.
    /// Берём с запасом: перевод не должен падать из-за пограничного случая.
    static let defaultLimit = 480

    /// Режет по границам предложений, длинные предложения — по словам.
    /// Слово длиннее лимита рвётся по символам, иначе оно потерялось бы целиком.
    static func chunks(_ text: String, limit: Int = defaultLimit) -> [String] {
        guard limit > 0 else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > limit else { return [trimmed] }

        var result: [String] = []
        var current = ""

        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty { result.append(piece) }
            current = ""
        }

        for sentence in sentences(of: trimmed) {
            if sentence.count > limit {
                flush()
                result.append(contentsOf: splitLongPiece(sentence, limit: limit))
                continue
            }
            if current.count + sentence.count > limit {
                flush()
            }
            current += sentence
        }
        flush()
        return result
    }

    /// Предложения вместе с завершающими пробелами, чтобы склейка не слипалась.
    private static func sentences(of text: String) -> [String] {
        var result: [String] = []
        text.enumerateSubstrings(
            in: text.startIndex..<text.endIndex,
            options: [.bySentences, .substringNotRequired]
        ) { _, range, enclosingRange, _ in
            result.append(String(text[enclosingRange]))
            _ = range
        }
        return result.isEmpty ? [text] : result
    }

    private static func splitLongPiece(_ piece: String, limit: Int) -> [String] {
        var result: [String] = []
        var current = ""

        for word in piece.split(separator: " ", omittingEmptySubsequences: false) {
            let word = String(word)
            if word.count > limit {
                if !current.isEmpty { result.append(current); current = "" }
                result.append(contentsOf: splitByCharacters(word, limit: limit))
                continue
            }
            let candidate = current.isEmpty ? word : current + " " + word
            if candidate.count > limit {
                if !current.isEmpty { result.append(current) }
                current = word
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { result.append(current) }
        return result.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    private static func splitByCharacters(_ word: String, limit: Int) -> [String] {
        var result: [String] = []
        var index = word.startIndex
        while index < word.endIndex {
            let end = word.index(index, offsetBy: limit, limitedBy: word.endIndex) ?? word.endIndex
            result.append(String(word[index..<end]))
            index = end
        }
        return result
    }
}
