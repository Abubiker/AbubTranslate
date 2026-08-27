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
        /// Локальная нейронка OPUS.
        case workingLocal
        /// Системный движок не умеет пару — ушли в облачный запасной.
        case workingCloud
        case done
        case failed(String)
        /// Локальная модель не скачана — в панели покажем кнопку в настройки.
        case failedNeedsDownload(String)
        /// Оригинал уже на целевом языке. `suggestion` — что предложить кнопкой.
        case sameLanguage(detected: Locale.Language, suggestion: Locale.Language?)
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
    private var sourceRetranslateTask: Task<Void, Never>?
    /// Последний уже переведённый оригинал — чтобы правка текста не гоняла
    /// один и тот же запрос повторно.
    private var lastTranslatedSource = ""
    private let speech = SpeechManager()
    private let clipboard = ClipboardManager()
    private let selection = SelectionReader()
    let hotKeys = HotKeyManager()
    private let localTranslator = LocalNeuralTranslator()
    let modelDownloader = ModelDownloader.shared

    var isWorking: Bool {
        status == .working || status == .preparing || status == .workingLocal || status == .workingCloud
    }

    /// Последний перевод пришёл из облака, а не с устройства.
    var lastUsedCloud = false
    var lastUsedLocal = false
    var lastProviderName: String?
    var isSpeaking: Bool { speech.isSpeaking }
    var canSpeak: Bool { !translatedText.isEmpty || speech.lastSpokenText != nil }

    private init() {
        KeychainHelper.migrateIfNeeded()
        migrateLegacyTargetLanguage()
        migrateEngineModeIfNeeded()
        currentTargetCode = targetLanguageCode
        Task { await loadAvailableLanguages() }
    }

    // MARK: - Языковая пара

    /// Список на случай, если LanguageAvailability ещё не ответил.
    static let fallbackLanguageCodes = [
        "ru", "en", "uk", "de", "fr", "es", "it", "pt",
        "zh", "ja", "ko", "ar", "tr", "pl", "nl", "cs",
    ]

    /// Язык перевода. Явный, а не выведенный из пары: пара A⇄B не показывала,
    /// куда именно уйдёт текст, и требовала эвристик для языков вне пары.
    /// Ключ новый — `targetLanguage` занят легаси-значением первой версии.
    var targetLanguageCode: String {
        get {
            if let stored = UserDefaults.standard.string(forKey: "targetLanguageV2"), !stored.isEmpty {
                return stored
            }
            return Self.systemLanguageCode
        }
        set { UserDefaults.standard.set(newValue, forKey: "targetLanguageV2") }
    }

    /// Язык macOS, если движок его знает, иначе английский.
    static var systemLanguageCode: String {
        guard let code = Locale.current.language.languageCode?.identifier else { return "en" }
        return fallbackLanguageCodes.contains(code) ? code : "en"
    }

    /// Язык-источник: nil = авто-определение (NLLanguageRecognizer), иначе фиксированный код.
    /// Показывается в меню как "Auto-detect".
    var sourceLanguageCode: String? {
        get {
            let raw = UserDefaults.standard.string(forKey: "sourceLanguage")
            if raw == nil || raw == "auto" || raw?.isEmpty == true { return nil }
            return raw
        }
        set {
            if let v = newValue, !v.isEmpty, v != "auto" {
                UserDefaults.standard.set(v, forKey: "sourceLanguage")
            } else {
                UserDefaults.standard.removeObject(forKey: "sourceLanguage")
            }
        }
    }

    /// Вызывается из SettingsView при смене источника — инвалидирует кэш и перезапускает перевод вне сеттера.
    func setSourceLanguageAndRetranslate(_ code: String?) {
        let old = sourceLanguageCode
        sourceLanguageCode = code
        guard old != code else { return }
        lastTranslatedSource = ""
        sourceRetranslateTask?.cancel()
        guard !sourceText.isEmpty else { return }
        sourceRetranslateTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard !Task.isCancelled, let self else { return }
            self.translate(text: self.sourceText)
        }
    }

    var sourceLanguage: Locale.Language? {
        guard let code = sourceLanguageCode else { return nil }
        return Locale.Language(identifier: code)
    }

    // Динамический список языков для текущего движка (для меню A/B). Кэшируем сортировку.
    private var cachedTargetCodes: [String]?
    private var cachedTargetEngine: EngineMode?
    private var cachedTargetAppleCodes: [String]?

    var targetAvailableCodes: [String] {
        if let cached = cachedTargetCodes,
           cachedTargetEngine == engineMode,
           cachedTargetAppleCodes == availableLanguageCodes
        {
            return cached
        }
        let codes = EngineLanguageSupport.codes(for: engineMode, appleAvailable: availableLanguageCodes)
        var seen = Set<String>()
        let sorted = codes.filter { seen.insert($0).inserted }.sorted { displayName(for: $0) < displayName(for: $1) }
        cachedTargetCodes = sorted
        cachedTargetEngine = engineMode
        cachedTargetAppleCodes = availableLanguageCodes
        return sorted
    }

    /// Для меню источника: Auto + тот же набор.
    var sourceAvailableCodes: [String] {
        targetAvailableCodes
    }

    // MARK: - Движок перевода

    var engineMode: EngineMode {
        get {
            if let raw = UserDefaults.standard.string(forKey: "translationEngine"),
               let mode = EngineMode.migrated(from: raw)
            {
                return mode
            }
            return .appleOnly
        }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: "translationEngine")
        }
    }

    private func migrateEngineModeIfNeeded() {
        // Если ключ уже есть — только legacy миграция
        if let raw = UserDefaults.standard.string(forKey: "translationEngine") {
            if let migrated = EngineMode.migrated(from: raw), migrated.rawValue != raw {
                UserDefaults.standard.set(migrated.rawValue, forKey: "translationEngine")
            }
            return
        }
        // Старого ключа нет — миграция cloudFallback или дефолт
        if UserDefaults.standard.object(forKey: "cloudFallback") != nil {
            let oldCloud = UserDefaults.standard.object(forKey: "cloudFallback") as? Bool ?? true
            let migrated: EngineMode = oldCloud ? .hfCloud : .appleOnly
            UserDefaults.standard.set(migrated.rawValue, forKey: "translationEngine")
        } else {
            UserDefaults.standard.set(EngineMode.appleOnly.rawValue, forKey: "translationEngine")
        }
    }

    // MARK: - Облачный запасной переводчик (legacy для MyMemory почты)

    /// Включён по умолчанию: срабатывает только там, где системный движок
    /// бессилен, иначе функция была бы бесполезна без похода в настройки.
    /// Оставлен для миграции, новый код использует engineMode.
    var cloudFallbackEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "cloudFallback") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "cloudFallback") }
    }

    /// Необязательная почта — поднимает суточный лимит MyMemory.
    var cloudContactEmail: String {
        get { UserDefaults.standard.string(forKey: "cloudEmail") ?? "" }
        set { UserDefaults.standard.set(newValue, forKey: "cloudEmail") }
    }

    var cloudProviderName: String {
        lastProviderName ?? CloudTranslator().providerName
    }

    // Провайдеры облака для RU-friendly цепочки
    var huggingFaceToken: String? {
        get { KeychainHelper.huggingFaceToken }
        set { KeychainHelper.huggingFaceToken = newValue }
    }

    var libreTranslateURL: String? {
        get { KeychainHelper.libreTranslateURL }
        set { KeychainHelper.libreTranslateURL = newValue }
    }

    var libreTranslateApiKey: String? {
        get { KeychainHelper.load(for: "libre_api_key") }
        set {
            if let v = newValue, !v.isEmpty { KeychainHelper.save(v, for: "libre_api_key") }
            else { KeychainHelper.delete(for: "libre_api_key") }
        }
    }

    var targetLanguage: Locale.Language { Locale.Language(identifier: targetLanguageCode) }

    /// Менять местами нечего, пока исходный язык неизвестен.
    var canSwap: Bool {
        sourceLanguageCode != nil || detectedLanguage != nil
    }

    /// Источник ⇄ цель: прежний источник фиксируется как цель, прежняя цель
    /// становится заданным вручную источником.
    func swapLanguages() {
        guard let current = sourceLanguage ?? detectedLanguage,
              let currentCode = current.languageCode?.identifier
        else { return }
        let previousTarget = targetLanguageCode
        targetLanguageCode = currentCode
        sourceLanguageCode = previousTarget
        lastTranslatedSource = ""
        if !sourceText.isEmpty {
            translate(text: sourceText)
        }
    }

    /// Пара A/B → один целевой язык. Старые ключи не удаляем, просто
    /// перестаём читать: откат на предыдущую сборку останется рабочим.
    private func migrateLegacyTargetLanguage() {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "targetLanguageV2") == nil else { return }
        // Язык системы и есть новое поведение по умолчанию, старая пара
        // ничего полезного о желаемой цели не сообщала.
        defaults.set(Self.systemLanguageCode, forKey: "targetLanguageV2")
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
        // Инвалидируем кэш targetAvailableCodes чтобы меню сразу увидело новые языки
        cachedTargetCodes = nil
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
        effectiveLocale.localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    // MARK: - Локаль интерфейса (отдельно от пары перевода)

    enum AppLocale: String, CaseIterable {
        case auto = "auto"
        case ru = "ru"
        case en = "en"

        var locale: Locale? {
            switch self {
            case .auto: return nil
            case .ru: return Locale(identifier: "ru")
            case .en: return Locale(identifier: "en")
            }
        }

        var displayName: String {
            switch self {
            case .auto: return String(localized: "Auto (System)")
            case .ru: return "Русский"
            case .en: return "English"
            }
        }
    }

    var appLocaleRaw: String {
        get { UserDefaults.standard.string(forKey: "appLocale") ?? "auto" }
        set { UserDefaults.standard.set(newValue, forKey: "appLocale") }
    }

    var appLocale: AppLocale {
        AppLocale(rawValue: appLocaleRaw) ?? .auto
    }

    var effectiveLocale: Locale {
        appLocale.locale ?? Locale.current
    }

    /// Для NSMenu вне SwiftUI — форсированная локализация по effectiveLocale
    func localizedString(_ key: String) -> String {
        if let loc = appLocale.locale,
           let path = Bundle.main.path(forResource: loc.identifier, ofType: "lproj"),
           let bundle = Bundle(path: path)
        {
            let v = bundle.localizedString(forKey: key, value: nil, table: nil)
            if v != key { return v }
        }
        return String(localized: String.LocalizationValue(key))
    }

    func languageName(_ language: Locale.Language, locale: Locale? = nil) -> String {
        let loc = locale ?? effectiveLocale
        return loc.localizedString(forIdentifier: language.minimalIdentifier)?.capitalized
            ?? language.minimalIdentifier
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

    /// Хранимое, а не вычисляемое: @Observable отслеживает только чтение
    /// хранимых свойств. С вычисляемым `AXIsProcessTrusted()` предупреждение
    /// оставалось на экране после выдачи разрешения — перерисовки не было.
    private(set) var hasAccessibility = SelectionReader.isTrusted

    var needsAccessibilityPermission: Bool { !hasAccessibility }

    func refreshAccessibility() {
        let current = SelectionReader.isTrusted
        if current != hasAccessibility { hasAccessibility = current }
    }

    func requestAccessibilityPermission() {
        SelectionReader.requestTrust()
        // Разрешение выдаётся в другом приложении; возврат фокуса ловим
        // отдельно, но подстрахуемся коротким опросом.
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(500))
                refreshAccessibility()
                if hasAccessibility { return }
            }
        }
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
        if sourceText != text { sourceText = text }
        lastTranslatedSource = text
        translatedText = ""
        lastUsedCloud = false
        lastUsedLocal = false
        lastProviderName = nil
        speech.stop()

        // Источник: либо фиксированный из настроек, либо авто-детект
        let detected: Locale.Language
        if let override = sourceLanguage {
            detected = override
        } else if let auto = LanguageDetector.detect(text) {
            detected = auto
        } else {
            status = .failed(String(localized: "Could not detect the source language"))
            return
        }
        detectedLanguage = detected

        // Переводить текст в его же язык бессмысленно. Молча подменять цель
        // не станем — предложим альтернативу кнопкой, решает пользователь.
        if TranslationDirection.sameLanguage(detected, targetLanguage) {
            let suggestion = TranslationDirection.suggestedAlternative(
                detected: detected,
                preferred: Locale.current.language,
                supported: targetAvailableCodes
            )
            status = .sameLanguage(detected: detected, suggestion: suggestion)
            return
        }

        status = .working
        pendingText = text

        // Цель ровно одна; движковые ветки ниже по-прежнему принимают список.
        let candidates = [targetLanguage]

        translationTask = Task { @MainActor [weak self] in
            guard let self else { return }
            switch self.engineMode {
            case .appleOnly:
                // Только Apple, без сети
                if await self.tryAppleTranslation(detected: detected, candidates: candidates) { return }
                guard !Task.isCancelled else { return }
                self.status = .failed(self.unsupportedMessage(for: detected))
                return

            case .appleMyMemory:
                // Apple → MyMemory
                if await self.tryAppleTranslation(detected: detected, candidates: candidates) { return }
                guard !Task.isCancelled else { return }
                await self.translateViaMyMemoryOnly(text: text, detected: detected, candidates: candidates)
                return

            case .localOnly:
                // Только локальная OPUS (оффлайн, без Apple)
                let done = await self.tryLocalTranslation(text: text, detected: detected, candidates: candidates)
                if done { return }
                guard !Task.isCancelled else { return }
                if case .failedNeedsDownload = self.status { return }
                // Если локаль не умеет — пробуем? Нет, т.к. только локальная
                self.status = .failed(self.unsupportedMessage(for: detected))
                return

            case .hfCloud:
                // Облачные модели HF: HF → Libre → MyMemory, без Apple/local
                await self.translateViaHFChain(text: text, detected: detected, candidates: candidates)
                return

            case .appleLocal:
                // Legacy: Apple → Local
                if await self.tryAppleTranslation(detected: detected, candidates: candidates) { return }
                guard !Task.isCancelled else { return }
                let done = await self.tryLocalTranslation(text: text, detected: detected, candidates: candidates)
                if done { return }
                guard !Task.isCancelled else { return }
                if case .failedNeedsDownload = self.status { return }
                self.status = .failed(self.unsupportedMessage(for: detected))
                return

            case .appleLocalCloud:
                // Legacy: Apple → Local → HF chain
                if await self.tryAppleTranslation(detected: detected, candidates: candidates) { return }
                guard !Task.isCancelled else { return }
                let done = await self.tryLocalTranslation(text: text, detected: detected, candidates: candidates)
                if done { return }
                // failedNeedsDownload уже выставлен, но пробуем cloud как fallback
                if case .failedNeedsDownload = self.status {
                    // не return — пробуем cloud
                } else if done {
                    return
                }
                guard !Task.isCancelled else { return }
                await self.translateViaHFChain(text: text, detected: detected, candidates: candidates)
                return
            }
        }
    }

    /// Кнопка из подсказки «текст уже на целевом языке».
    func retarget(to language: Locale.Language) {
        guard let code = language.languageCode?.identifier else { return }
        targetLanguageCode = code
        lastTranslatedSource = ""
        guard !sourceText.isEmpty else { return }
        translate(text: sourceText)
    }

    /// Пробует Apple Translation для кандидатов. true = запущен session.
    private func tryAppleTranslation(detected: Locale.Language, candidates: [Locale.Language]) async -> Bool {
        for target in candidates {
            let availability = await Self.availabilityStatus(from: detected, to: target)
            guard !Task.isCancelled else { return true }
            switch availability {
            case .installed, .supported:
                if availability == .supported {
                    self.status = .preparing
                }
                self.currentTargetCode = target.languageCode?.identifier ?? self.targetLanguageCode
                self.startSession(source: detected, target: target)
                return true
            case .unsupported:
                continue
            @unknown default:
                continue
            }
        }
        return false
    }

    private func tryLocalTranslation(
        text: String,
        detected: Locale.Language,
        candidates: [Locale.Language]
    ) async -> Bool {
        guard let target = candidates.first,
              let sourceCode = detected.languageCode?.identifier,
              let targetCode = target.languageCode?.identifier
        else { return false }

        let pairKey = modelDownloader.pairKey(from: sourceCode, to: targetCode)
        if !modelDownloader.isDownloaded(pairKey: pairKey) {
            status = .failedNeedsDownload(
                String(localized: "Local model for \(pairKey) is not downloaded. Open Settings to download it.")
            )
            return false
        }

        status = .workingLocal
        do {
            let result = try await localTranslator.translate(text, from: sourceCode, to: targetCode)
            guard !Task.isCancelled else { return true }
            currentTargetCode = targetCode
            lastUsedLocal = true
            lastProviderName = localTranslator.providerName
            finishTranslation(result)
            return true
        } catch is CancellationError {
            resetStatus()
            return true
        } catch let err as LocalNeuralTranslator.LocalError {
            switch err {
            case .notDownloaded(let pair):
                status = .failedNeedsDownload(
                    String(localized: "Local model for \(pair) is not downloaded. Open Settings to download it.")
                )
                return false
            default:
                // Даём шанс cloud если текущий режим его подразумевает
                if engineMode == .hfCloud || engineMode == .appleLocalCloud {
                    return false
                }
                status = .failed(err.localizedDescription)
                return true
            }
        } catch {
            if engineMode == .hfCloud || engineMode == .appleLocalCloud {
                return false
            }
            status = .failed(error.localizedDescription)
            return true
        }
    }

    private func activeCloudProviders(for mode: EngineMode? = nil) -> [any TranslationProvider] {
        let m = mode ?? engineMode
        switch m {
        case .appleMyMemory:
            var my = MyMemoryProvider()
            my.contactEmail = cloudContactEmail
            return [my]
        case .hfCloud, .appleLocalCloud:
            // HF приоритет, затем Libre, затем MyMemory
            var providers: [any TranslationProvider] = []
            let hf = HuggingFaceProvider()
            providers.append(hf)
            let libre = LibreTranslateProvider()
            providers.append(libre)
            var my = MyMemoryProvider()
            my.contactEmail = cloudContactEmail
            providers.append(my)
            return providers
        default:
            return []
        }
    }

    /// Делегирует на per-mode chain
    private func activeCloudProvidersLegacy() -> [any TranslationProvider] {
        activeCloudProviders()
    }

    /// Только MyMemory (для appleMyMemory)
    private func translateViaMyMemoryOnly(
        text: String,
        detected: Locale.Language,
        candidates: [Locale.Language]
    ) async {
        guard let target = candidates.first,
              let sourceCode = detected.languageCode?.identifier,
              let targetCode = target.languageCode?.identifier
        else {
            status = .failed(unsupportedMessage(for: detected))
            return
        }
        status = .workingCloud
        lastProviderName = "MyMemory"
        var my = MyMemoryProvider()
        my.contactEmail = cloudContactEmail
        do {
            let result = try await my.translate(text, from: sourceCode, to: targetCode)
            guard !Task.isCancelled else { return }
            currentTargetCode = targetCode
            lastUsedCloud = true
            lastProviderName = my.name
            finishTranslation(result)
        } catch is CancellationError {
            resetStatus()
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(error.localizedDescription)
        }
    }

    /// HF цепочка: HF → Libre → MyMemory
    private func translateViaHFChain(
        text: String,
        detected: Locale.Language,
        candidates: [Locale.Language]
    ) async {
        guard let target = candidates.first,
              let sourceCode = detected.languageCode?.identifier,
              let targetCode = target.languageCode?.identifier
        else {
            status = .failed(unsupportedMessage(for: detected))
            return
        }

        let providers = activeCloudProviders(for: .hfCloud)
        var lastError: String?

        for provider in providers {
            guard provider.isConfigured() else { continue }
            status = .workingCloud
            lastProviderName = provider.name
            do {
                let result = try await provider.translate(text, from: sourceCode, to: targetCode)
                guard !Task.isCancelled else { return }
                currentTargetCode = targetCode
                lastUsedCloud = true
                lastProviderName = provider.name
                finishTranslation(result)
                return
            } catch is CancellationError {
                resetStatus()
                return
            } catch let err as TranslationProviderError {
                switch err {
                case .quotaExceeded:
                    lastError = err.localizedDescription
                    continue
                case .service(let msg):
                    lastError = msg
                    continue
                default:
                    lastError = err.localizedDescription
                    continue
                }
            } catch {
                lastError = error.localizedDescription
                continue
            }
        }

        guard !Task.isCancelled else { return }
        if let err = lastError {
            status = .failed(err)
        } else {
            status = .failed(unsupportedMessage(for: detected))
        }
    }

    /// Цепочка облачных провайдеров — пробуем по очереди, пока один не вернёт результат.
    private func translateViaCloudChain(
        text: String,
        detected: Locale.Language,
        candidates: [Locale.Language]
    ) async {
        await translateViaHFChain(text: text, detected: detected, candidates: candidates)
    }

    /// Старый метод оставлен для совместимости, теперь делегирует в chain.
    private func translateViaCloud(
        text: String,
        detected: Locale.Language,
        candidates: [Locale.Language]
    ) async {
        await translateViaCloudChain(text: text, detected: detected, candidates: candidates)
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
}
