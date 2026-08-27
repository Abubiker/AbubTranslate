import Foundation

/// HuggingFace Inference API — бесплатная облачная нейронка.
/// Работает в RU без VPN, без привязки карты.
/// Рекомендуемые модели: Helsinki-NLP/opus-mt-*, facebook/nllb-200-distilled-600M
/// Free tier: anon rate-limit, с токеном лимит выше.
/// Docs: https://huggingface.co/docs/inference-providers
struct HuggingFaceProvider: TranslationProvider {
    let id = "huggingface"
    let name = "HuggingFace"
    /// NLLB токен лимит 512 — берём 500 с запасом для M-series ANE.
    let charLimit = 500
    let requiresKey = true // анонимный доступ HuggingFace отключил, токен обязателен

    var token: String? {
        KeychainHelper.huggingFaceToken
    }

    /// Предпочтительная модель. NLLB покрывает 200 языков одним весом.
    /// Helsinki opus-mt точнее для конкретных пар, но требует выбора модели per-pair.
    /// Для универсальности используем NLLB distilled как дефолт.
    var modelId: String = "facebook/nllb-200-distilled-600M"

    func isConfigured() -> Bool {
        // HuggingFace отключил анонимный доступ к router-инференсу — без
        // токена запрос всегда падает 401. Проверено вручную: curl без
        // заголовка Authorization получает 401 на router.huggingface.co.
        isTokenConfigured
    }

    var isTokenConfigured: Bool {
        guard let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return false }
        return true
    }

    func translate(_ text: String, from source: String, to target: String) async throws -> String {
        // HuggingFace router endpoint
        // Для NLLB коды вида "rus_Cyrl", "eng_Latn" — маппим из ISO 639-1.
        let hfSource = HuggingFaceLanguageMapper.toNLLB(source)
        let hfTarget = HuggingFaceLanguageMapper.toNLLB(target)

        var parts: [String] = []
        for chunk in TextChunker.chunks(text, limit: charLimit) {
            try Task.checkCancellation()
            let translated = try await translateChunk(
                chunk, from: hfSource, to: hfTarget, sourceRaw: source, targetRaw: target
            )
            parts.append(translated)
        }
        return parts.joined(separator: " ")
    }

    private func translateChunk(
        _ chunk: String,
        from source: String,
        to target: String,
        sourceRaw: String,
        targetRaw: String
    ) async throws -> String {
        // Новый Inference Providers endpoint: https://huggingface.co/docs/inference-providers
        // Используем router.huggingface.co
        guard let url = URL(string: "https://router.huggingface.co/hf-inference/models/\(modelId)") else {
            throw TranslationProviderError.badResponse
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 30
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let t = token?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            request.setValue("Bearer \(t)", forHTTPHeaderField: "Authorization")
        }

        // NLLB ожидает src_lang/tgt_lang в payload
        let payload: [String: Any] = [
            "inputs": chunk,
            "parameters": [
                "src_lang": source,
                "tgt_lang": target,
            ],
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw TranslationProviderError.badResponse
        }

        // 401 invalid token — сразу в fallback
        if http.statusCode == 401 {
            throw TranslationProviderError.service("HuggingFace token invalid (401) — check token or leave empty for anon")
        }
        // 429 quota — один ретрай с backoff 2с перед тем как сдаться, как для 503
        if http.statusCode == 429 {
            try? await Task.sleep(for: .seconds(2))
            try Task.checkCancellation()
            let (rData, rResp) = try await URLSession.shared.data(for: request)
            if let rHttp = rResp as? HTTPURLResponse, (200...299).contains(rHttp.statusCode) {
                return try decodeResponse(data: rData, http: rHttp)
            }
            throw TranslationProviderError.quotaExceeded
        }
        if http.statusCode == 503 {
            // Модель грузится — пробуем один ретрай через 2с
            try await Task.sleep(for: .seconds(2))
            try Task.checkCancellation()
            // Ретрай один раз
            let (data2, response2) = try await URLSession.shared.data(for: request)
            guard let http2 = response2 as? HTTPURLResponse, (200...299).contains(http2.statusCode) else {
                throw TranslationProviderError.service("Model is loading, try again shortly")
            }
            return try decodeResponse(data: data2, http: http2)
        }

        return try decodeResponse(data: data, http: http)
    }

    private func decodeResponse(data: Data, http: HTTPURLResponse) throws -> String {
        guard (200...299).contains(http.statusCode) else {
            let msg = String(data: data, encoding: .utf8) ?? "HTTP \(http.statusCode)"
            if msg.uppercased().contains("LIMIT") || msg.uppercased().contains("QUOTA") {
                throw TranslationProviderError.quotaExceeded
            }
            throw TranslationProviderError.service(msg)
        }

        // Ответ HF может быть [{"translation_text": "..."}] или {"translation_text": "..."}
        if let arr = try? JSONDecoder().decode([HFResponse].self, from: data),
           let first = arr.first, !first.translationText.isEmpty
        {
            return first.translationText
        }
        if let single = try? JSONDecoder().decode(HFResponse.self, from: data),
           !single.translationText.isEmpty
        {
            return single.translationText
        }
        // Иногда модель возвращает {"generated_text": "..."}
        if let alt = try? JSONDecoder().decode(HFAltResponse.self, from: data),
           let text = alt.generatedText ?? alt.translationText, !text.isEmpty
        {
            return text
        }
        throw TranslationProviderError.badResponse
    }

    private struct HFResponse: Decodable {
        let translationText: String

        enum CodingKeys: String, CodingKey {
            case translationText = "translation_text"
        }
    }

    private struct HFAltResponse: Decodable {
        let generatedText: String?
        let translationText: String?

        enum CodingKeys: String, CodingKey {
            case generatedText = "generated_text"
            case translationText = "translation_text"
        }
    }
}

/// Маппер ISO 639-1 -> NLLB код (Flores-200)
enum HuggingFaceLanguageMapper {
    static func toNLLB(_ iso: String) -> String {
        // Минимальная карта для самых частых языков. Остальные — fallback как есть + "_Latn"
        // Полная таблица: https://github.com/facebookresearch/flores/blob/main/flores200/README.md
        let map: [String: String] = [
            "en": "eng_Latn",
            "ru": "rus_Cyrl",
            "de": "deu_Latn",
            "fr": "fra_Latn",
            "es": "spa_Latn",
            "it": "ita_Latn",
            "pt": "por_Latn",
            "zh": "zho_Hans",
            "ja": "jpn_Jpan",
            "ko": "kor_Hang",
            "ar": "arb_Arab",
            "tr": "tur_Latn",
            "pl": "pol_Latn",
            "nl": "nld_Latn",
            "cs": "ces_Latn",
            "uk": "ukr_Cyrl",
            "sv": "swe_Latn",
            "da": "dan_Latn",
            "nb": "nob_Latn",
            "fi": "fin_Latn",
            "id": "ind_Latn",
            "vi": "vie_Latn",
            "th": "tha_Thai",
            "hi": "hin_Deva",
            "uz": "uzn_Latn",
            "kk": "kaz_Cyrl",
            "ky": "kir_Cyrl",
            "be": "bel_Cyrl",
            "az": "azj_Latn",
            "ka": "kat_Geor",
            "hy": "hye_Armn",
            "ro": "ron_Latn",
            "hu": "hun_Latn",
            "bg": "bul_Cyrl",
            "sr": "srp_Cyrl",
            "hr": "hrv_Latn",
            "sk": "slk_Latn",
            "sl": "slv_Latn",
            "et": "est_Latn",
            "lv": "lvs_Latn",
            "lt": "lit_Latn",
            "el": "ell_Grek",
            "he": "heb_Hebr",
        ]
        if let mapped = map[iso.lowercased()] { return mapped }
        // Fallback: определяем скрипт по коду — кириллица → _Cyrl, иначе _Latn
        let cyrillic: Set<String> = ["ru","uk","be","bg","sr","mk","kk","ky","tg","tt","ba","cv","ce","mn","ab","os"]
        let suffix = cyrillic.contains(iso.lowercased()) ? "_Cyrl" : "_Latn"
        return "\(iso.lowercased())\(suffix)"
    }
}
