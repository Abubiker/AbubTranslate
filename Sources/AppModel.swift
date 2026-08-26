import SwiftUI
import Translation

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Status: Equatable {
        case idle
        case working
        /// Языковой пакет ещё не скачан — система тянет его в фоне.
        case preparing
        /// Системный движок не умеет пару — ушли в облачный запасной.
        case workingCloud
        case done
        case failed(String)
    }

    var sourceText = ""
    var translatedText = ""
    var status: Status = .idle
    var detectedLanguage: Locale.Language?
    var translationConfig: TranslationSession.Configuration?

    /// Языки, которые реально умеет движок на этой машине.
    /// Пока не загрузились — `fallbackLanguageCodes`.
    var availableLanguageCodes: [String] = AppModel.fallbackLanguageCodes

    /// Коллбеки показа панели и окна настроек — подставляет AppDelegate.
    var showPanel: (() -> Void)?
    var showSettings: (() -> Void)?

    private var pendingText = ""
    private var translationTask: Task<Void, Never>?
    private var autoTranslateTask: Task<Void, Never>?
    /// Последний уже переведённый оригинал — чтобы правка текста не гоняла
    /// один и тот же запрос повторно.
    private var lastTranslatedSource = ""
    private let speech = SpeechManager()
    private let clipboard = ClipboardManager()
    private let selection = SelectionReader()
    let hotKeys = HotKeyManager()

    var isWorking: Bool { status == .working || status == .preparing || status == .workingCloud }

    /// Последний перевод пришёл из облака, а не с устройства.
    var lastUsedCloud = false
    var isSpeaking: Bool { speech.isSpeaking }
    var canSpeak: Bool { !translatedText.isEmpty || speech.lastSpokenText != nil }

    private init() {
        migrateLegacyTargetLanguage()
        Task { await loadAvailableLanguages() }
    }

    // MARK: - Языковая пара

    /// Список на случай, если LanguageAvailability ещё не ответил.
    static let fallbackLanguageCodes = [
        "ru", "en", "uk", "de", "fr", "es", "it", "pt",
        "zh", "ja", "ko", "ar", "tr", "pl", "nl", "cs",
    ]

    var languageCodeA: String {
        get { UserDefaults.standard.string(forKey: "languageA") ?? "ru" }
        set { UserDefaults.standard.set(newValue, forKey: "languageA") }
    }

    var languageCodeB: String {
        get { UserDefaults.standard.string(forKey: "languageB") ?? "en" }
        set { UserDefaults.standard.set(newValue, forKey: "languageB") }
    }

    // MARK: - Облачный запасной переводчик

    /// Включён по умолчанию: срабатывает только там, где системный движок
    /// бессилен, иначе функция была бы бесполезна без похода в настройки.
    var cloudFallbackEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cloudFallback") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cloudFallback") }
    }

    /// Необязательная почта — поднимает суточный лимит MyMemory.
    var cloudContactEmail: String {
        get { UserDefaults.standard.string(forKey: "cloudEmail") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cloudEmail") }
    }

    var cloudProviderName: String { CloudTranslator().providerName }

    var languageA: Locale.Language { Locale.Language(identifier: languageCodeA) }
    var languageB: Locale.Language { Locale.Language(identifier: languageCodeB) }

    func swapLanguages() {
        let a = languageCodeA
        languageCodeA = languageCodeB
        languageCodeB = a
        if !sourceText.isEmpty {
            translate(text: sourceText)
        }
    }

    /// Старая одиночная настройка `targetLanguage` → пара A/B.
    private func migrateLegacyTargetLanguage() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "languageA") == nil,
              let legacy = defaults.string(forKey: "targetLanguage")
        else { return }
        defaults.set(legacy, forKey: "languageA")
        defaults.set(legacy == "en" ? "ru" : "en", forKey: "languageB")
    }

    private func loadAvailableLanguages() async {
        let languages = await Self.fetchSupportedLanguages()
        var seen = Set<String>()
        let codes = languages
            .compactMap { $0.languageCode?.identifier }
            .filter { seen.insert($0).inserted }
            .sorted { displayName(for: $0) < displayName(for: $1) }
        guard !codes.isEmpty else { return }
        availableLanguageCodes = codes
    }

    /// LanguageAvailability не Sendable — держим его целиком вне main actor.
    private nonisolated static func fetchSupportedLanguages() async -> [Locale.Language] {
        await LanguageAvailability().supportedLanguages
    }

    private nonisolated static func availabilityStatus(
        from source: Locale.Language,
        to target: Locale.Language
    ) async -> LanguageAvailability.Status {
        await LanguageAvailability().status(from: source, to: target)
    }

    func displayName(for code: String) -> String {
        Locale.current.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    // MARK: - Тема оформления

    var appearanceMode: String {
        get { UserDefaults.standard.string(forKey: "appearanceMode") ?? "system" }
        set {
            UserDefaults.standard.set(newValue, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    func applyAppearance() {
        switch UserDefaults.standard.string(forKey: "appearanceMode") ?? "system" {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    // MARK: - Хоткеи

    func startHotKeys() {
        hotKeys.onKeyDown = { [weak self] slot in
            Task { @MainActor in
                self?.handleHotKey(slot)
            }
        }
        applyHotKey(.translate)
        applyHotKey(.speak)
    }

    /// `false` — комбинация занята другим приложением.
    @discardableResult
    func applyHotKey(_ slot: HotKeyManager.Slot) -> Bool {
        let binding = HotkeyBinding.load(slot: slot)
        return hotKeys.register(slot: slot, keyCode: binding.keyCode, modifiers: binding.modifiers)
    }

    nonisolated func handleHotKey(_ slot: HotKeyManager.Slot) {
        switch slot {
        case .translate:
            Task { @MainActor in activateFromHotKey() }
        case .speak:
            Task { @MainActor in speakLastTranslation() }
        }
    }

    // MARK: - Действия

    /// Хоткей перевода: сначала пробуем выделение в активном приложении,
    /// иначе откатываемся на буфер обмена.
    ///
    /// Порядок важен: панель показываем ПОСЛЕ чтения выделения. Показ
    /// активирует наше приложение, и синтетический ⌘C ушёл бы в саму панель.
    func activateFromHotKey() {
        Task { @MainActor in
            let selected = await selection.readSelection()
            showPanel?()
            if let selected, !selected.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                translate(text: selected)
            } else {
                translateFromClipboard()
            }
        }
    }

    /// Текст в поле оригинала изменили руками или вставили.
    /// Переводим сами, с паузой — иначе запрос уходил бы на каждый символ.
    func sourceTextEdited(_ text: String) {
        sourceText = text
        autoTranslateTask?.cancel()

        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            // Поле очистили — возвращаемся в исходное состояние, а не в ошибку.
            translationTask?.cancel()
            translatedText = ""
            detectedLanguage = nil
            lastTranslatedSource = ""
            status = .idle
            return
        }
        guard trimmed != lastTranslatedSource else { return }

        autoTranslateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, let self else { return }
            self.translate(text: text)
        }
    }

    func translateFromClipboard() {
        translate(text: clipboard.readText() ?? "")
    }

    var needsAccessibilityPermission: Bool { !SelectionReader.isTrusted }

    func requestAccessibilityPermission() {
        SelectionReader.requestTrust()
    }

    func speakLastTranslation() {
        let text = translatedText.isEmpty ? (speech.lastSpokenText ?? "") : translatedText
        guard !text.isEmpty else { return }
        speech.toggleSpeakLast(text: text, languageCode: currentTargetCode)
    }

    func stopSpeech() {
        speech.stop()
    }

    /// Язык последнего перевода — для озвучки нужным голосом.
    private var currentTargetCode = "en"

    // MARK: - Перевод

    func translate(text rawText: String) {
        translationTask?.cancel()
        autoTranslateTask?.cancel()

        let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            sourceText = ""
            translatedText = ""
            status = .failed(String(localized: "Nothing to translate"))
            return
        }
        // Присваиваем только при реальном отличии: иначе обрезка пробелов
        // дёргает поле прямо под курсором во время набора.
        if sourceText != text { sourceText = text }
        lastTranslatedSource = text
        translatedText = ""
        lastUsedCloud = false
        speech.stop()

        guard let detected = LanguageDetector.detect(text) else {
            status = .failed(String(localized: "Could not detect the source language"))
            return
        }
        detectedLanguage = detected

        status = .working
        pendingText = text

        let candidates = TranslationDirection.targetCandidates(
            detected: detected,
            a: languageA,
            b: languageB,
            preferred: Locale.current.language
        )

        translationTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // Пробуем оба языка пары: движок может не уметь A, но уметь B.
            for target in candidates {
                let availability = await Self.availabilityStatus(from: detected, to: target)
                guard !Task.isCancelled else { return }
                switch availability {
                case .installed, .supported:
                    if availability == .supported {
                        // Пакет придётся качать — иначе панель выглядит зависшей.
                        self.status = .preparing
                    }
                    self.currentTargetCode = target.languageCode?.identifier ?? self.languageCodeB
                    self.startSession(source: detected, target: target)
                    return
                case .unsupported:
                    continue
                @unknown default:
                    continue
                }
            }

            guard !Task.isCancelled else { return }
            await self.translateViaCloud(text: text, detected: detected, candidates: candidates)
        }
    }

    /// Системный движок не потянул ни одно направление — пробуем облако.
    private func translateViaCloud(
        text: String,
        detected: Locale.Language,
        candidates: [Locale.Language]
    ) async {
        guard cloudFallbackEnabled,
              let target = candidates.first,
              let sourceCode = detected.languageCode?.identifier,
              let targetCode = target.languageCode?.identifier
        else {
            status = .failed(unsupportedMessage(for: detected))
            return
        }

        status = .workingCloud
        var translator = CloudTranslator()
        translator.contactEmail = cloudContactEmail

        do {
            let result = try await translator.translate(text, from: sourceCode, to: targetCode)
            guard !Task.isCancelled else { return }
            currentTargetCode = targetCode
            lastUsedCloud = true
            finishTranslation(result)
        } catch is CancellationError {
            resetStatus()
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(error.localizedDescription)
        }
    }

    /// Различаем «движок не знает такой язык вообще» и «не умеет это
    /// направление»: первое встречается чаще и чинится только сменой текста.
    private func unsupportedMessage(for detected: Locale.Language) -> String {
        let name = languageName(detected)
        guard let code = detected.languageCode?.identifier,
              availableLanguageCodes.contains(code)
        else {
            return String(localized: "Apple Translation does not support \(name)")
        }
        return String(localized: "No supported translation direction from \(name)")
    }

    /// `.translationTask` перезапускается только при смене конфигурации,
    /// поэтому для той же пары языков дёргаем `invalidate()`.
    private func startSession(source: Locale.Language, target: Locale.Language) {
        if var config = translationConfig, config.source == source, config.target == target {
            config.invalidate()
            translationConfig = config
        } else {
            translationConfig = TranslationSession.Configuration(source: source, target: target)
        }
    }

    /// Вызывается из `.translationTask` до старта перевода.
    func takePendingText() -> String {
        let pending = pendingText
        pendingText = ""
        return pending
    }

    func finishTranslation(_ result: String) {
        translatedText = result
        status = .done
    }

    func failTranslation(_ message: String) {
        status = .failed(message)
    }

    func resetStatus() {
        status = .idle
    }

    func copyResult() {
        guard !translatedText.isEmpty else { return }
        clipboard.writeText(translatedText)
    }

    func languageName(_ language: Locale.Language) -> String {
        Locale.current.localizedString(forIdentifier: language.minimalIdentifier)?.capitalized
            ?? language.minimalIdentifier
    }
}
