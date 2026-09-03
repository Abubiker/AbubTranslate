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

    var isWorking: Bool {
        status == .working || status == .preparing || status == .workingCloud
    }

    /// Последний перевод пришёл из облака, а не с устройства.
    var lastUsedCloud = false
    var lastProviderName: String?
    var isSpeaking: Bool { speech.isSpeaking }
    var canSpeak: Bool { !translatedText.isEmpty || speech.lastSpokenText != nil }

    private init() {
        KeychainHelper.migrateIfNeeded()
        migrateLegacyTargetLanguage()
        migrateEngineModeIfNeeded()
        currentTargetCode = targetLanguageCode
        // Резолвнутый при первом запуске язык надо сразу записать:
        // appLocalizedString читает "appLocale" из UserDefaults напрямую,
        // без записи все не-UI строки (ошибки облака) говорили бы по-английски.
        if UserDefaults.standard.string(forKey: "appLocale") == nil {
            UserDefaults.standard.set(appLocaleRaw, forKey: "appLocale")
        }
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
    private var cachedTargetLocaleId: String?

    func englishDisplayName(for code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized ?? code
    }

    var targetAvailableCodes: [String] {
        let localeId = effectiveLocale.identifier
        if let cached = cachedTargetCodes,
           cachedTargetEngine == engineMode,
           cachedTargetAppleCodes == availableLanguageCodes,
           cachedTargetLocaleId == localeId
        {
            return cached
        }
        let rawCodes = EngineLanguageSupport.codes(for: engineMode, appleAvailable: availableLanguageCodes)
        // скрыть редкие коды без английского имени (alz, bbc и т.д.) — они дают сырой код в списке
        let codes = rawCodes.filter { hasDisplayName($0) }
        var seen = Set<String>()
        // сортировка всегда по en для стабильности, отображение — на языке интерфейса
        let sorted = codes.filter { seen.insert($0).inserted }.sorted { englishDisplayName(for: $0) < englishDisplayName(for: $1) }
        cachedTargetCodes = sorted
        cachedTargetEngine = engineMode
        cachedTargetAppleCodes = availableLanguageCodes
        cachedTargetLocaleId = localeId
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
            let migrated: EngineMode = oldCloud ? .appleMyMemory : .appleOnly
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
    var azureKey: String? {
        get { KeychainHelper.azureKey }
        set { KeychainHelper.azureKey = newValue }
    }

    /// Не секрет — не в Keychain по необходимости, а для единообразия с ключом.
    var azureRegion: String? {
        get { KeychainHelper.azureRegion }
        set { KeychainHelper.azureRegion = newValue }
    }

    var googleKey: String? {
        get { KeychainHelper.googleKey }
        set { KeychainHelper.googleKey = newValue }
    }

    var deepLKey: String? {
        get { KeychainHelper.deepLKey }
        set { KeychainHelper.deepLKey = newValue }
    }

    var openAIBaseURL: String? {
        get { UserDefaults.standard.string(forKey: "openai_base_url") }
        set { UserDefaults.standard.set(newValue, forKey: "openai_base_url") }
    }

    var openAIModel: String? {
        get { UserDefaults.standard.string(forKey: "openai_model") }
        set { UserDefaults.standard.set(newValue, forKey: "openai_model") }
    }

    var openAIKey: String? {
        get { KeychainHelper.openAIKey }
        set { KeychainHelper.openAIKey = newValue }
    }

    /// Гасить reasoning-токены у family-моделей (DeepSeek/Qwen/o-серия) —
    /// по умолчанию включено: без этого перевод через deepseek-r1-подобные
    /// модели ждёт десятки секунд на размышлениях вслух.
    var openAIDisableThinking: Bool {
        get { UserDefaults.standard.object(forKey: "openai_disable_thinking") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "openai_disable_thinking") }
    }

    var yandexKey: String? {
        get { KeychainHelper.yandexKey }
        set { KeychainHelper.yandexKey = newValue }
    }

    /// Не секрет — каталог Yandex Cloud, обязателен только для ключей
    /// обычного пользователя (ключ сервисного аккаунта не требует).
    var yandexFolderId: String? {
        get { UserDefaults.standard.string(forKey: "yandex_folder_id") }
        set { UserDefaults.standard.set(newValue, forKey: "yandex_folder_id") }
    }

    var libreTranslateBaseURL: String? {
        get { UserDefaults.standard.string(forKey: "libretranslate_base_url") }
        set { UserDefaults.standard.set(newValue, forKey: "libretranslate_base_url") }
    }

    var libreTranslateKey: String? {
        get { KeychainHelper.libreTranslateKey }
        set { KeychainHelper.libreTranslateKey = newValue }
    }

    var targetLanguage: Locale.Language { Locale.Language(identifier: targetLanguageCode) }

    /// Менять местами нечего, пока исходный язык неизвестен.
    var canSwap: Bool {
        sourceLanguageCode != nil || detectedLanguage != nil
    }

    /// Источник ⇄ цель. Если перевод уже есть — меняем местами и текст:
    /// результат становится оригиналом, прежний источник — целью, языки
    /// следуют за текстом. Прежняя версия разворачивала только пару, а текст
    /// оставляла на месте: английский оригинал с навязанным ru-источником
    /// возвращался тем же английским — выглядело как неработающая кнопка.
    /// Если перевода ещё нет — разворот пары с прежними подсказками для
    /// дублей, источник отдаётся авто-детекту.
    func swapLanguages() {
        guard let current = sourceLanguage ?? detectedLanguage,
              let currentCode = current.languageCode?.identifier
        else { return }
        let previousTarget = targetLanguageCode
        if !translatedText.isEmpty {
            sourceText = translatedText
            translatedText = ""
            targetLanguageCode = currentCode
            sourceLanguageCode = previousTarget
        } else {
            let prevLang = Locale.Language(identifier: previousTarget)
            if TranslationDirection.sameLanguage(current, prevLang) {
                if let alt = TranslationDirection.suggestedAlternative(
                    detected: current,
                    preferred: effectiveLocale.language,
                    supported: targetAvailableCodes
                ), let altCode = alt.languageCode?.identifier {
                    targetLanguageCode = altCode
                    sourceLanguageCode = previousTarget
                } else {
                    return
                }
            } else {
                targetLanguageCode = currentCode
                sourceLanguageCode = previousTarget
            }
        }
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
            .sorted { englishDisplayName(for: $0) < englishDisplayName(for: $1) }
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
        if let v = effectiveLocale.localizedString(forLanguageCode: code)?.capitalized, !v.isEmpty { return v }
        if let v = Locale(identifier: "en").localizedString(forLanguageCode: code)?.capitalized, !v.isEmpty { return v }
        return code
    }

    private func hasDisplayName(_ code: String) -> Bool {
        Locale(identifier: "en").localizedString(forLanguageCode: code) != nil
    }

    // MARK: - Локаль интерфейса (отдельно от пары перевода)

    /// Open-source на все страны — без «Авто» как отдельного режима: при
    /// первом запуске резолвится в конкретный язык один раз
    /// (resolveInitialLanguage), дальше это обычный явный выбор.
    enum InterfaceLanguage: String, CaseIterable {
        case en, ru, es, fr, de, pt, zh, ja, ar, hi

        /// Имя языка на нём самом — не через String(localized:), это имя
        /// собственное, показывается одинаково независимо от текущего
        /// интерфейсного языка (тот же принцип, что уже был у "Русский"/"English").
        var displayName: String {
            switch self {
            case .en: return "English"
            case .ru: return "Русский"
            case .es: return "Español"
            case .fr: return "Français"
            case .de: return "Deutsch"
            case .pt: return "Português"
            case .zh: return "中文"
            case .ja: return "日本語"
            case .ar: return "العربية"
            case .hi: return "हिन्दी"
            }
        }
    }

    /// Языки без собственного перевода в приложении, для которых система
    /// на постсоветском пространстве — откат на русский вместо английского,
    /// ближе этой аудитории. Не ограничение функциональности: весь список
    /// из 10 языков доступен вручную сразу же, это только дефолт первого
    /// запуска.
    private static let cisFallbackCodes: Set<String> = [
        "uk", "be", "kk", "uz", "ky", "tg", "tk", "hy", "az", "ka",
    ]

    private static func resolveInitialLanguage() -> String {
        let preferred = Locale.preferredLanguages
            .compactMap { Locale(identifier: $0).language.languageCode?.identifier }
        if let match = preferred.first(where: { InterfaceLanguage(rawValue: $0) != nil }) {
            return match
        }
        if let first = preferred.first, cisFallbackCodes.contains(first) { return "ru" }
        return "en"
    }

    /// Хранимое, а не вычисляемое: @Observable отслеживает только чтение
    /// хранимых свойств. Раньше это был computed поверх UserDefaults — смена
    /// языка в Settings писала UserDefaults, но SettingsView/PanelView
    /// (оба через .environment(\.locale, model.effectiveLocale), а
    /// effectiveLocale тоже computed сверху appLocaleRaw) не
    /// перерисовывались вообще: интерфейс молча оставался на старом языке,
    /// быстрое переключение туда-сюда выглядело как "не успевает". Тот же
    /// класс бага, что уже чинили для hasAccessibility.
    var appLocaleRaw: String = UserDefaults.standard.string(forKey: "appLocale")
        ?? AppModel.resolveInitialLanguage()
    {
        didSet {
            guard oldValue != appLocaleRaw else { return }
            UserDefaults.standard.set(appLocaleRaw, forKey: "appLocale")
        }
    }

    var effectiveLocale: Locale {
        Locale(identifier: appLocaleRaw)
    }

    /// Форсированная локализация по appLocaleRaw — нужна для ЛЮБОГО текста
    /// вне тела SwiftUI View (NSMenu, сообщения об ошибках AppModel):
    /// String(localized:) там не видит .environment(\.locale:), берёт
    /// системный язык напрямую, игнорируя выбор пользователя в приложении.
    /// appLocaleRaw всегда конкретный код (нет больше "auto"), поэтому без
    /// опциональной развёртки, в отличие от прежней версии.
    ///
    /// Тонкая обёртка над appLocalizedString(_:_:) (см. ниже, вне класса) —
    /// та же логика, просто с готовым appLocaleRaw вместо чтения
    /// UserDefaults заново. Обе части экрана (эта и enum'ы в
    /// TranslationProvider/CloudTranslator) должны резолвиться одинаково.
    func localizedString(_ key: String, _ args: CVarArg...) -> String {
        localizedStringCore(forLanguageCode: appLocaleRaw, key: key, args: args)
    }

    func languageName(_ language: Locale.Language, locale: Locale? = nil) -> String {
        let loc = locale ?? effectiveLocale
        return loc.localizedString(forIdentifier: language.minimalIdentifier)?.capitalized
            ?? language.minimalIdentifier
    }

    // MARK: - Тема оформления

    /// Раньше было вычисляемым свойством поверх UserDefaults — @Observable
    /// не отслеживает чтения вычисляемых свойств, только хранимых, поэтому
    /// смена темы никогда не помечала зависящие View (например, Panel) как
    /// требующие перерисовки: тема применялась только если view пересчитывал
    /// body по какой-то другой, отслеживаемой причине. Тот же паттерн фикса,
    /// что раньше уже применялся к appLocaleRaw.
    var appearanceMode: String = UserDefaults.standard.string(forKey: "appearanceMode") ?? "system" {
        didSet {
            guard oldValue != appearanceMode else { return }
            UserDefaults.standard.set(appearanceMode, forKey: "appearanceMode")
            applyAppearance()
        }
    }

    func applyAppearance() {
        switch appearanceMode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    /// NSApp.appearance не всегда докатывается до SwiftUI-контента внутри
    /// NSPopover (панель перевода) — попап кеширует appearance на момент
    /// показа и не всегда переоценивает её при смене темы в Settings.
    /// preferredColorScheme на самой SwiftUI-view — прямой и надёжный путь,
    /// в обход этого квирка AppKit.
    ///
    /// Для "system" НЕ отдаём nil: SwiftUI ненадёжно снимает ранее явно
    /// применённый .dark/.light обратно на nil в уже живущей (не заново
    /// создаваемой) иерархии — экран оставался тёмным после переключения
    /// на "Системная". Резолвим "system" в конкретный .light/.dark по
    /// текущему системному состоянию — не переоценивается сама при живой
    /// смене темы ОС без участия пользователя (редкий кейс, чинится любым
    /// повторным открытием панели/настроек).
    var preferredColorScheme: ColorScheme? {
        switch appearanceMode {
        case "light": return .light
        case "dark": return .dark
        default:
            return NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light
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
            // Хоткей — точка, в которой пользователь уже мог выдать доступ в
            // System Settings: обновляем флаг здесь, чтобы плашка в настройках
            // не доживала до следующего didBecomeActive.
            refreshAccessibility()
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

    /// Перезапуск приложения: после самонастройки/self-update запись
    /// «Универсального доступа» в System Settings остаётся за прежним
    /// cdhash — тумблер включён, живой процесс не доверен, плашка не
    /// гаснет. Лечится только новым запуском текущей сборки.
    /// Паттерн — как `UpdateChecker.scheduleRestart`: `open` срабатывает
    /// уже после termination, запас 2с — на случай медленного закрытия
    /// (иначе `open` попал бы в живой процесс, reopen suppressed → приложение
    /// умерло бы без перезапуска).
    func restartApp() {
        let path = Bundle.main.bundlePath
        let script = "sleep 2; /usr/bin/open \"\(path)\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script]
        do {
            try process.run()
        } catch {
            NSLog("AbubTranslate restart error: \(error.localizedDescription)")
            return
        }
        NSApp.terminate(nil)
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
            status = .failed(localizedString("Nothing to translate"))
            return
        }
        if sourceText != text { sourceText = text }
        lastTranslatedSource = text
        translatedText = ""
        lastUsedCloud = false
        lastProviderName = nil
        speech.stop()

        // Источник: либо фиксированный из настроек, либо авто-детект
        let detected: Locale.Language
        if let override = sourceLanguage {
            detected = override
        } else if let auto = LanguageDetector.detect(text) {
            detected = auto
        } else {
            status = .failed(localizedString("Could not detect the source language"))
            return
        }
        detectedLanguage = detected

        // Переводить текст в его же язык бессмысленно. Молча подменять цель
        // не станем — предложим альтернативу кнопкой, решает пользователь.
        if TranslationDirection.sameLanguage(detected, targetLanguage) {
            let suggestion = TranslationDirection.suggestedAlternative(
                detected: detected,
                preferred: effectiveLocale.language,
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

            case .appleMyMemory:
                // Apple → MyMemory
                if await self.tryAppleTranslation(detected: detected, candidates: candidates) { return }
                guard !Task.isCancelled else { return }
                await self.translateViaMyMemoryOnly(text: text, detected: detected, candidates: candidates)

            case .azureCloud:
                // Облачные модели: Azure Translator (требует ключ) → MyMemory, без Apple
                await self.translateViaCloudChain(mode: .azureCloud, text: text, detected: detected, candidates: candidates)

            case .googleCloud:
                // Облачные модели: Google Translate (требует ключ) → MyMemory, без Apple
                await self.translateViaCloudChain(mode: .googleCloud, text: text, detected: detected, candidates: candidates)

            case .deepLCloud:
                // Облачные модели: DeepL (требует ключ) → MyMemory, без Apple
                await self.translateViaCloudChain(mode: .deepLCloud, text: text, detected: detected, candidates: candidates)

            case .openAICompatible:
                // OpenAI-совместимый LLM (требует baseURL+key+model) → MyMemory, без Apple
                await self.translateViaCloudChain(mode: .openAICompatible, text: text, detected: detected, candidates: candidates)

            case .yandexCloud:
                // Облачные модели: Yandex Cloud Translate (требует ключ) → MyMemory, без Apple
                await self.translateViaCloudChain(mode: .yandexCloud, text: text, detected: detected, candidates: candidates)

            case .libreTranslate:
                // Облачные модели: LibreTranslate-инстанс (URL, ключ опц.) → MyMemory, без Apple
                await self.translateViaCloudChain(mode: .libreTranslate, text: text, detected: detected, candidates: candidates)
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

    private func activeCloudProviders(for mode: EngineMode? = nil) -> [any TranslationProvider] {
        let m = mode ?? engineMode
        switch m {
        case .appleMyMemory:
            var my = MyMemoryProvider()
            my.contactEmail = cloudContactEmail
            return [my]
        case .azureCloud:
            var my = MyMemoryProvider()
            my.contactEmail = cloudContactEmail
            return [AzureTranslatorProvider(), my]
        case .googleCloud:
            var my = MyMemoryProvider()
            my.contactEmail = cloudContactEmail
            return [GoogleTranslateProvider(), my]
        case .deepLCloud:
            var my = MyMemoryProvider()
            my.contactEmail = cloudContactEmail
            return [DeepLProvider(), my]
        case .openAICompatible:
            var my = MyMemoryProvider()
            my.contactEmail = cloudContactEmail
            return [OpenAICompatibleProvider(), my]
        case .yandexCloud:
            var my = MyMemoryProvider()
            my.contactEmail = cloudContactEmail
            return [YandexTranslateProvider(), my]
        case .libreTranslate:
            var my = MyMemoryProvider()
            my.contactEmail = cloudContactEmail
            return [LibreTranslateProvider(), my]
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
            return
        } catch {
            guard !Task.isCancelled else { return }
            status = .failed(error.localizedDescription)
        }
    }

    /// Общая цепочка для облачных движков: HuggingFace→MyMemory,
    /// Azure→MyMemory — перебираем провайдеров по очереди для `mode`, пока
    /// один не вернёт результат. Раньше это было отдельной функцией только
    /// под HuggingFace плюс два мёртвых метода-обёртки без вызовов
    /// (translateViaCloud → translateViaCloudChain → тот же самый chain) —
    /// убраны, при добавлении Azure проще было обобщить, чем плодить копию.
    private func translateViaCloudChain(
        mode: EngineMode,
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

        let providers = activeCloudProviders(for: mode)
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

    /// Различаем «движок не знает такой язык вообще» и «не умеет это
    /// направление»: первое встречается чаще и чинится только сменой текста.
    private func unsupportedMessage(for detected: Locale.Language) -> String {
        let name = languageName(detected)
        guard let code = detected.languageCode?.identifier,
              availableLanguageCodes.contains(code)
        else {
            return localizedString("Apple Translation does not support %@", name)
        }
        return localizedString("No supported translation direction from %@", name)
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

    /// Флаг фидбека копирования: панель показывает всплывающую ✓ и свой
    /// таймер возврата иконки. Повторный клик перезапускает таймер, а не
    /// оставляет две гонящие задачи.
    var copiedFlash = false
    private var copyFlashTask: Task<Void, Never>?

    func copyResult() {
        guard !translatedText.isEmpty else { return }
        clipboard.writeText(translatedText)
        copyFlashTask?.cancel()
        copiedFlash = true
        copyFlashTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard !Task.isCancelled, let self else { return }
            self.copiedFlash = false
        }
    }

    /// Полный сброс панели: переоткрытое окно не должно показывать
    /// висящий с прошлого раза перевод.
    func clearAll() {
        translationTask?.cancel()
        autoTranslateTask?.cancel()
        sourceRetranslateTask?.cancel()
        speech.stop()
        sourceText = ""
        translatedText = ""
        detectedLanguage = nil
        lastTranslatedSource = ""
        lastUsedCloud = false
        lastProviderName = nil
        copiedFlash = false
        status = .idle
    }
}

/// Ядро локализации по конкретному коду языка — nonisolated: вызывается и
/// из @MainActor (AppModel.localizedString) и из non-isolated мест
/// (EngineMode/TranslationProviderError в TranslationProvider.swift,
/// CloudTranslator.Failure) — те не привязаны к main actor, их методы
/// могут выполняться в фоновом Task при сетевых ошибках провайдеров, и
/// обратиться оттуда к MainActor-изолированному AppModel.shared без await
/// нельзя (Swift 6 concurrency checker).
nonisolated func localizedStringCore(forLanguageCode code: String, key: String, args: [CVarArg]) -> String {
    let template: String
    if let path = Bundle.main.path(forResource: code, ofType: "lproj"),
       let bundle = Bundle(path: path)
    {
        // value:key — отсутствующий ключ возвращает сам ключ. Ключи — исходный
        // английский текст, поэтому непереведённая строка остаётся английской,
        // а не уезжает в системный язык macOS. Прежняя эвристика `v != key`
        // считала пропуском любое совпадение значения с ключом — а dev-регион
        // en.lproj ровно так и хранит (key = value), из-за чего на RU-системе
        // при выбранном английском движок показывал «Облачные модели (OpenAI)».
        template = bundle.localizedString(forKey: key, value: key, table: nil)
    } else {
        template = key
    }
    return args.isEmpty ? template : String(format: template, arguments: args)
}

/// Для non-isolated контекстов — код языка читаем напрямую из
/// UserDefaults (сам по себе потокобезопасен), а не через
/// MainActor-изолированный AppModel.shared.appLocaleRaw.
nonisolated func appLocalizedString(_ key: String, _ args: CVarArg...) -> String {
    let code = UserDefaults.standard.string(forKey: "appLocale") ?? "en"
    return localizedStringCore(forLanguageCode: code, key: key, args: args)
}
