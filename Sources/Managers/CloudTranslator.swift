import Foundation

/// Запасной переводчик на случай, когда системный движок не умеет пару языков
/// (финский, чешский и прочие, которых нет в Apple Translation).
///
/// MyMemory: без ключа и без привязки карты, 5000 слов в сутки анонимно и
/// 50 000 при указании почты. Взамен — лимит 500 символов на запрос, поэтому
/// длинный текст режется `TextChunker` и склеивается обратно.
///
/// ВАЖНО: это сетевой запрос. Текст покидает устройство.
struct CloudTranslator {
    enum Failure: LocalizedError {
        case quotaExceeded
        case service(String)
        case badResponse

        var errorDescription: String? {
            // appLocalizedString(_:), не String(localized:) —
            // вне тела View игнорирует .environment(\.locale:).
            switch self {
            case .quotaExceeded:
                appLocalizedString("Daily cloud translation quota is used up")
            case .service(let message):
                message
            case .badResponse:
                appLocalizedString("Cloud translator returned an unexpected response")
            }
        }
    }

    /// Необязательная почта — поднимает суточный лимит с 5 000 до 50 000 слов.
    var contactEmail: String?

    private let endpoint = URL(string: "https://api.mymemory.translated.net/get")!

    var providerName: String { "MyMemory" }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        var parts: [String] = []
        for piece in TextChunker.pieces(text) {
            try Task.checkCancellation()
            let translated = try await translateChunk(piece.text, from: source, to: target)
            parts.append(translated + piece.trailing)
        }
        return parts.joined()
    }

    private func translateChunk(
        _ chunk: String,
        from source: String,
        to target: String
    ) async throws -> String {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        var items = [
            URLQueryItem(name: "q", value: chunk),
            URLQueryItem(name: "langpair", value: "\(source)|\(target)"),
        ]
        if let email = contactEmail?.trimmingCharacters(in: .whitespaces), !email.isEmpty {
            items.append(URLQueryItem(name: "de", value: email))
        }
        components.queryItems = items

        var request = URLRequest(url: components.url!)
        request.timeoutInterval = 20

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Failure.badResponse }

        let decoded = try? JSONDecoder().decode(Payload.self, from: data)

        // Лимит запросов MyMemory отдаёт и кодом 429, и текстом внутри 200.
        let details = decoded?.responseDetails ?? ""
        if http.statusCode == 429 || details.uppercased().contains("LIMIT") {
            throw Failure.quotaExceeded
        }
        guard let decoded, decoded.responseStatus.intValue == 200 else {
            throw details.isEmpty ? Failure.badResponse : Failure.service(details)
        }
        let result = decoded.responseData.translatedText
        guard !result.isEmpty else { throw Failure.badResponse }
        return result
    }

    // MARK: - Ответ сервиса

    private struct Payload: Decodable {
        struct ResponseData: Decodable { let translatedText: String }
        /// responseStatus приходит то числом, то строкой — принимаем оба.
        struct LooseInt: Decodable {
            let intValue: Int
            init(from decoder: Decoder) throws {
                let container = try decoder.singleValueContainer()
                if let value = try? container.decode(Int.self) {
                    intValue = value
                } else if let text = try? container.decode(String.self), let value = Int(text) {
                    intValue = value
                } else {
                    intValue = -1
                }
            }
        }
        let responseData: ResponseData
        let responseStatus: LooseInt
        let responseDetails: String?
    }
}
