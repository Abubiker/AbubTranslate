import Foundation

/// Нарезка текста на куски под лимит запроса облачного переводчика.
///
/// Зависит только от Foundation — логику можно прогнать без сборки приложения,
/// см. `Tools/SelfCheck.swift`.
enum TextChunker {
    /// MyMemory отвечает 403 на запрос длиннее 500 символов.
    /// Берём с запасом: перевод не должен падать из-за пограничного случая.
    static let defaultLimit = 480

    /// Кусок текста плюс исходный whitespace сразу после него. Сервисы
    /// обрезают ответ, а склеивающая сторона дописывает `trailing` к
    /// переводу — так переносы абзацев не теряются на длинном тексте.
    struct Piece: Equatable {
        let text: String
        let trailing: String
    }

    /// Режет по границам предложений, длинные предложения — по словам.
    /// Слово длиннее лимита рвётся по символам, иначе оно потерялось бы целиком.
    static func chunks(_ text: String, limit: Int = defaultLimit) -> [String] {
        pieces(text, limit: limit).map(\.text)
    }

    /// Та же нарезка, что `chunks`, но с исходным whitespace после каждого куска.
    static func pieces(_ text: String, limit: Int = defaultLimit) -> [Piece] {
        guard limit > 0 else { return [] }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        guard trimmed.count > limit else { return [Piece(text: trimmed, trailing: "")] }

        var result: [Piece] = []
        var current = ""

        func flush() {
            let piece = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !piece.isEmpty, let range = current.range(of: piece) {
                result.append(Piece(text: piece, trailing: String(current[range.upperBound...])))
            }
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

    private static func splitLongPiece(_ piece: String, limit: Int) -> [Piece] {
        var result: [Piece] = []
        var current = ""
        var separator = ""

        for (word, trailing) in words(of: piece) {
            if word.isEmpty {
                separator += trailing
                continue
            }
            if word.count > limit {
                if !current.isEmpty {
                    result.append(Piece(text: current, trailing: separator))
                    current = ""
                }
                let parts = splitByCharacters(word, limit: limit)
                for (index, part) in parts.enumerated() {
                    let trailing = index == parts.count - 1 ? trailing : ""
                    result.append(Piece(text: part, trailing: trailing))
                }
                separator = ""
                continue
            }
            let candidate = current.isEmpty ? word : current + separator + word
            if !current.isEmpty, candidate.count > limit {
                result.append(Piece(text: current, trailing: separator))
                current = word
            } else {
                current = candidate
            }
            separator = trailing
        }
        if !current.isEmpty {
            result.append(Piece(text: current, trailing: separator))
        }
        return result
    }

    /// Слово + идущий за ним пробельный прогон. Whitespace режет и абзацы,
    /// и обычные пробелы — раньше «слово\nслово» считалось одним словом
    /// и при длинном предложении летело в splitByCharacters целиком.
    private static func words(of piece: String) -> [(text: String, trailing: String)] {
        var result: [(text: String, trailing: String)] = []
        var index = piece.startIndex
        while index < piece.endIndex {
            var end = index
            while end < piece.endIndex, !piece[end].isWhitespace {
                end = piece.index(after: end)
            }
            var trailEnd = end
            while trailEnd < piece.endIndex, piece[trailEnd].isWhitespace {
                trailEnd = piece.index(after: trailEnd)
            }
            result.append((text: String(piece[index..<end]), trailing: String(piece[end..<trailEnd])))
            index = trailEnd
        }
        return result
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
