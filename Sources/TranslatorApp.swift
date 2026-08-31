import AppKit
import SwiftUI
@preconcurrency import Translation
import UserNotifications

@main
struct TranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        AppModel.shared.startHotKeys()
    }

    // Окно настроек создаёт AppDelegate вручную: сцена Settings открывается
    // только приватным селектором showSettingsWindow:, который из accessory
    // приложения без строки меню не срабатывает.
    var body: some Scene {
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem?
    /// Базовая иконка менюбара — к ней возвращается статус после
    /// загрузки/установки обновления.
    private var statusIcon: NSImage?
    private let popover = NSPopover()
    private var settingsWindow: NSWindow?
    /// Чтобы не долбить GitHub лишний раз: баннер/алерт на одну найденную
    /// версию показывается один раз за запуск.
    private var notifiedVersion: String?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "AbubTranslateStatusItem"
        item.isVisible = true
        if let button = item.button {
            statusIcon = NSImage(named: "StatusIcon")
            if statusIcon == nil {
                statusIcon = NSImage(systemSymbolName: "translate", accessibilityDescription: "AbubTranslate")
            }
            if let icon = statusIcon {
                icon.isTemplate = true
                icon.size = NSSize(width: 20, height: 20)
                button.image = icon
            } else {
                button.title = "A⇄Я"
            }
            button.action = #selector(statusItemClicked)
            button.target = self
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item

        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        // Высоту задаёт сам SwiftUI-контент: панель ужимается под короткий
        // перевод и растёт под длинный, вместо фиксированных 560pt с пустотами.
        let hosting = NSHostingController(
            rootView: PanelView().environment(AppModel.shared)
        )
        hosting.sizingOptions = [.preferredContentSize]
        popover.contentViewController = hosting

        AppModel.shared.showPanel = { [weak self] in
            self?.togglePopover()
        }
        // Шестерёнка в панели идёт тем же путём, что и пункт меню: SwiftUI
        // openSettings из поповера окно не поднимает.
        AppModel.shared.showSettings = { [weak self] in
            self?.openSettingsFromMenu()
        }
        AppModel.shared.applyAppearance()

        // Разрешение выдают в Настройках системы: ловим возврат фокуса,
        // иначе предупреждение висит до перезапуска приложения.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated { AppModel.shared.refreshAccessibility() }
        }

        // Тестовый вход: позволяет проверить окно настроек без кликов мышью.
        if ProcessInfo.processInfo.arguments.contains("--open-settings") {
            openSettingsFromMenu()
        }

        // Диагностика облачных движков: реальный запрос от лица уже
        // доверенного процесса, без нового бинарника — тот получал бы
        // диалог доступа к Keychain, а этот его уже давно прошёл.
        if ProcessInfo.processInfo.arguments.contains("--azure-selftest") {
            Task { await runAzureSelfTest() }
        }
        if ProcessInfo.processInfo.arguments.contains("--google-selftest") {
            Task { await runGoogleSelfTest() }
        }
        if ProcessInfo.processInfo.arguments.contains("--deepl-selftest") {
            Task { await runDeepLSelfTest() }
        }
        if ProcessInfo.processInfo.arguments.contains("--update-selftest") {
            Task { await runUpdateSelfTest() }
        }

        // Самоаппдейт: подчистить осколки прерванной установки, затем
        // плановая проверка (не чаще раза в сутки, внутри checker).
        // Задержка — чтобы не спорить за сеть/процессор со стартовыми
        // загрузками языков.
        UpdateChecker.cleanStaleUpdateArtifacts()
        UNUserNotificationCenter.current().delegate = self
        UpdateChecker.shared.onAvailable = { [weak self] version in
            self?.announceUpdate(version)
        }
        // Перезапуск после установки: сказать, что обновление дошло,
        // иначе тихая замена себя выглядит как «ничего не произошло».
        if let from = UpdateChecker.shared.takeCompletedUpdate() {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                announceUpdateInstalled(to: UpdateChecker.shared.currentVersion, from: from)
            }
        }
        observeUpdateStatus()
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            UpdateChecker.shared.checkOncePerDay()
        }
    }

    private func selfTestLog(_ line: String) {
        let logURL = URL(fileURLWithPath: NSHomeDirectory() + "/Library/Logs/AbubTranslate.log")
        let data = Data((line + "\n").utf8)
        if let handle = try? FileHandle(forWritingTo: logURL) {
            handle.seekToEndOfFile()
            handle.write(data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }

    /// Контракт собран строго по официальной документации Microsoft, живым
    /// запросом не проверен — завести Azure-аккаунт с картой приложение не
    /// может (см. правила: не заводить аккаунты за пользователя). Прогнать
    /// эту самопроверку можно, как только в настройках сохранён реальный
    /// ключ: `open -a /Applications/AbubTranslate.app --args --azure-selftest`.
    private func runAzureSelfTest() async {
        let log = selfTestLog
        let provider = AzureTranslatorProvider()
        log("=== Azure selftest ===")
        log("key найден: \(provider.key != nil), длина: \(provider.key?.count ?? 0)")
        log("region: \(provider.region ?? "не задан (ок для global-ресурса)")")
        log("isConfigured(): \(provider.isConfigured())")

        guard provider.isConfigured() else {
            log("нет ключа — сохраните его в настройках и повторите")
            return
        }

        let pairs: [(String, String, String)] = [
            ("en", "ru", "Hello, how are you?"),
            ("ru", "en", "Привет, как дела?"),
            ("en", "de", "Good morning"),
        ]
        for (src, tgt, text) in pairs {
            do {
                let result = try await provider.translate(text, from: src, to: tgt)
                log("\(src)->\(tgt): УСПЕХ: \(result)")
            } catch {
                log("\(src)->\(tgt): ОШИБКА: \(error.localizedDescription)")
            }
        }

        let model = AppModel.shared
        let previousEngine = model.engineMode
        let previousTarget = model.targetLanguageCode
        model.engineMode = .azureCloud
        model.targetLanguageCode = "ru"
        model.translate(text: "Hello, this is an Azure chain test")
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if case .done = model.status { break }
            if case .failed = model.status { break }
        }
        log("цепочка azureCloud: status=\(model.status), lastProvider=\(model.lastProviderName ?? "nil"), lastUsedCloud=\(model.lastUsedCloud), text=\(model.translatedText)")
        model.engineMode = previousEngine
        model.targetLanguageCode = previousTarget

        log("=== конец Azure selftest ===")
    }

    /// Контракт собран по официальной документации Google Cloud, живым
    /// запросом не проверен — то же ограничение, что у Azure: завести GCP-
    /// проект с биллингом за пользователя приложение не может. Прогнать
    /// можно тем же приёмом: `--args --google-selftest`, как только в
    /// настройках сохранён реальный ключ.
    private func runGoogleSelfTest() async {
        let log = selfTestLog
        let provider = GoogleTranslateProvider()
        log("=== Google selftest ===")
        log("key найден: \(provider.key != nil), длина: \(provider.key?.count ?? 0)")
        log("isConfigured(): \(provider.isConfigured())")

        guard provider.isConfigured() else {
            log("нет ключа — сохраните его в настройках и повторите")
            return
        }

        let pairs: [(String, String, String)] = [
            ("en", "ru", "Hello, how are you?"),
            ("ru", "en", "Привет, как дела?"),
            ("en", "de", "Good morning"),
        ]
        for (src, tgt, text) in pairs {
            do {
                let result = try await provider.translate(text, from: src, to: tgt)
                log("\(src)->\(tgt): УСПЕХ: \(result)")
            } catch {
                log("\(src)->\(tgt): ОШИБКА: \(error.localizedDescription)")
            }
        }

        let model = AppModel.shared
        let previousEngine = model.engineMode
        let previousTarget = model.targetLanguageCode
        model.engineMode = .googleCloud
        model.targetLanguageCode = "ru"
        model.translate(text: "Hello, this is a Google chain test")
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if case .done = model.status { break }
            if case .failed = model.status { break }
        }
        log("цепочка googleCloud: status=\(model.status), lastProvider=\(model.lastProviderName ?? "nil"), lastUsedCloud=\(model.lastUsedCloud), text=\(model.translatedText)")
        model.engineMode = previousEngine
        model.targetLanguageCode = previousTarget

        log("=== конец Google selftest ===")
    }

    /// Контракт подтверждён живым запросом к developers.deepl.com/docs (не
    /// за CAPTCHA, в отличие от бывшего Yandex), но не живым запросом к
    /// самому API — завести DeepL-аккаунт с ключом приложение не может
    /// сделать за пользователя. DeepL сам блокирует запросы с российских
    /// IP на уровне сети — этот self-test может не пройти из России, даже
    /// с валидным ключом. Прогнать можно тем же приёмом: `--args
    /// --deepl-selftest`, как только в настройках сохранён реальный ключ.
    private func runDeepLSelfTest() async {
        let log = selfTestLog
        let provider = DeepLProvider()
        log("=== DeepL selftest ===")
        log("key найден: \(provider.key != nil), длина: \(provider.key?.count ?? 0)")
        log("isConfigured(): \(provider.isConfigured())")

        guard provider.isConfigured() else {
            log("нет ключа — сохраните его в настройках и повторите")
            return
        }

        let pairs: [(String, String, String)] = [
            ("en", "ru", "Hello, how are you?"),
            ("ru", "en", "Привет, как дела?"),
            ("en", "de", "Good morning"),
        ]
        for (src, tgt, text) in pairs {
            do {
                let result = try await provider.translate(text, from: src, to: tgt)
                log("\(src)->\(tgt): УСПЕХ: \(result)")
            } catch {
                log("\(src)->\(tgt): ОШИБКА: \(error.localizedDescription)")
            }
        }

        let model = AppModel.shared
        let previousEngine = model.engineMode
        let previousTarget = model.targetLanguageCode
        model.engineMode = .deepLCloud
        model.targetLanguageCode = "ru"
        model.translate(text: "Hello, this is a DeepL chain test")
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(500))
            if case .done = model.status { break }
            if case .failed = model.status { break }
        }
        log("цепочка deepLCloud: status=\(model.status), lastProvider=\(model.lastProviderName ?? "nil"), lastUsedCloud=\(model.lastUsedCloud), text=\(model.translatedText)")
        model.engineMode = previousEngine
        model.targetLanguageCode = previousTarget

        log("=== конец DeepL selftest ===")
    }

    @objc private func statusItemClicked() {
        let event = NSApp.currentEvent
        // Control-клик macOS доставляет как левый с модификатором.
        if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            showStatusMenu()
            return
        }
        // Клик по иконке только открывает панель. Перевод запускают хоткей
        // и вставка текста в поле оригинала — иначе панель нельзя открыть,
        // не тронув буфер обмена.
        togglePopover()
    }

    /// Правый клик по иконке — стандартное меню меню-бар утилиты.
    /// Выход живёт здесь, а не кнопкой в панели рядом с «Настройками».
    ///
    /// Меню показывается через `statusItem.menu` + `performClick`, а не через
    /// `NSMenu.popUp(in:)`: попап внутри обработчика действия конфликтует с
    /// собственным отслеживанием мыши у статус-кнопки и молча не открывается.
    /// Сразу после показа `menu` снимается, иначе левый клик перестанет
    /// доходить до `action` и панель не будет открываться.
    private func showStatusMenu() {
        guard let item = statusItem, let button = item.button else { return }
        if popover.isShown { popover.performClose(nil) }

        let menu = NSMenu()
        let checker = UpdateChecker.shared
        let updateTitle: String
        let updateBusy: Bool
        switch checker.status {
        case .available(let version):
            updateTitle = AppModel.shared.localizedString("Update available (%@)…", version)
            updateBusy = false
        case .checking:
            updateTitle = AppModel.shared.localizedString("Checking…")
            updateBusy = true
        case .downloading:
            updateTitle = AppModel.shared.localizedString("Downloading…")
                + " \(Int((checker.downloadProgress * 100).rounded(.down)))%"
            updateBusy = true
        case .installing:
            updateTitle = AppModel.shared.localizedString("Installing…")
            updateBusy = true
        default:
            updateTitle = AppModel.shared.localizedString("Check for Updates…")
            updateBusy = false
        }
        let update = menu.addItem(
            withTitle: updateTitle,
            action: #selector(checkForUpdatesFromMenu),
            keyEquivalent: ""
        )
        update.target = self
        update.isEnabled = !updateBusy
        menu.addItem(.separator())
        let settings = menu.addItem(
            withTitle: AppModel.shared.localizedString("Settings…"),
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(
            withTitle: AppModel.shared.localizedString("Quit AbubTranslate"),
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quit.target = self

        // Меню снимаем в menuDidClose, а не сразу после performClick:
        // performClick не блокирует, и синхронная очистка убивала меню
        // раньше, чем оно успевало показаться.
        menu.delegate = self
        item.menu = menu
        button.performClick(nil)
    }

    func menuDidClose(_ menu: NSMenu) {
        // Снять обязательно, иначе левый клик уйдёт в меню вместо действия
        // и панель перестанет открываться.
        DispatchQueue.main.async { [weak self] in
            self?.statusItem?.menu = nil
        }
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    /// Своё окно настроек вместо сцены SwiftUI: сцену можно открыть только
    /// приватным селектором, а он у accessory-приложения без строки меню
    /// не находит цели и молча ничего не делает.
    @objc private func openSettingsFromMenu() {
        if popover.isShown { popover.performClose(nil) }

        let window = settingsWindow ?? makeSettingsWindow()
        settingsWindow = window
        window.title = AppModel.shared.localizedString("AbubTranslate Settings")
        window.center()
        // activate(ignoringOtherApps:) на macOS 14+ deprecated и молча не
        // активирует приложение — окно оставалось позади чужих окон.
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    private func makeSettingsWindow() -> NSWindow {
        let controller = NSHostingController(
            rootView: SettingsView().environment(AppModel.shared)
        )
        let window = NSWindow(contentViewController: controller)
        window.identifier = NSUserInterfaceItemIdentifier("AbubTranslateSettings")
        window.title = AppModel.shared.localizedString("AbubTranslate Settings")
        window.styleMask = [.titled, .closable, .resizable]
        window.minSize = NSSize(width: 640, height: 640)
        window.setContentSize(NSSize(width: 720, height: 760))
        // Окно переживает закрытие: пересоздавать его на каждый показ значит
        // терять состояние полей и каждый раз платить за сборку иерархии.
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.moveToActiveSpace]
        window.center()
        return window
    }

    func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate()
        if let window = button.window, window.screen != nil {
            // Кэшируем позицию иконки на каждый показ — статус-бар мог перестроиться
            // (другие иконки добавились/пропали), фолбэку нужна свежая точка, а не протухшая.
            lastKnownIconCenterX = window.convertToScreen(button.convert(button.bounds, to: nil)).midX
            // Обычный путь: поповер из иконки в статус-баре.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            // Статус-итем спрятан (переполненный меню-бар или менеджер иконок) —
            // анкерим поповер к невидимой панели под меню-баром активного экрана.
            showPopoverViaFallbackAnchor()
        }
        installOutsideClickMonitor()
    }

    private var fallbackAnchorPanel: NSPanel?
    private var lastKnownIconCenterX: CGFloat?
    private var outsideClickMonitor: Any?

    /// .transient должен сам закрывать поповер по клику вне, но на практике
    /// не закрывает — вероятно из-за NSApp.activate() перед каждым показом
    /// в сочетании с .accessory-политикой приложения. Дублируем закрытие
    /// явным глобальным монитором: он видит клики только в ДРУГИХ
    /// приложениях, свою иконку это не задевает — там уже работает toggle.
    private func installOutsideClickMonitor() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            self?.popover.performClose(nil)
        }
    }

    private func showPopoverViaFallbackAnchor() {
        // Экран под курсором — тот меню-бар, на который смотрит пользователь.
        // NSScreen.main привязан к key-окну и на втором мониторе врёт.
        let mouse = NSEvent.mouseLocation
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(mouse) })
            ?? NSScreen.main ?? NSScreen.screens.first
        else { return }
        let menuBarHeight = NSStatusBar.system.thickness
        let anchor = fallbackAnchorPanel ?? {
            let panel = NSPanel(
                contentRect: .zero,
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.level = .popUpMenu
            panel.ignoresMouseEvents = true
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            fallbackAnchorPanel = panel
            return panel
        }()
        // Поповер центрируется по анкеру, значит анкер = правый край минус пол-ширины.
        // contentSize до первого показа нулевой, поэтому берём ширину панели.
        let halfWidth = max(popover.contentSize.width, PanelView.width) / 2
        let margin: CGFloat = 12
        // Иконка спрятана — якорим по её последней видимой позиции, а не по курсору,
        // иначе поповер прыгает по экрану вслед за мышью. Курсор — запасной вариант
        // только пока иконка ни разу не была видна в эту сессию (маловероятно —
        // она появляется сразу при запуске).
        let anchorX = lastKnownIconCenterX ?? mouse.x
        let x = min(
            max(screen.visibleFrame.minX + halfWidth + margin, anchorX),
            screen.frame.maxX - halfWidth - margin
        )
        let y = screen.frame.maxY - menuBarHeight - 4
        anchor.setFrame(NSRect(x: x, y: y, width: 1, height: 1), display: false)
        anchor.orderFront(nil)
        if let content = anchor.contentView {
            popover.show(relativeTo: content.bounds, of: content, preferredEdge: .minY)
        }
    }

    // MARK: - NSPopoverDelegate

    func popoverDidClose(_ notification: Notification) {
        fallbackAnchorPanel?.orderOut(nil)
        if let monitor = outsideClickMonitor {
            NSEvent.removeMonitor(monitor)
            outsideClickMonitor = nil
        }
    }

    // MARK: - Обновления

    /// Ручная проверка из меню: всегда с ответом пользователю, без тишины.
    @objc private func checkForUpdatesFromMenu() {
        Task { @MainActor in
            let status = await UpdateChecker.shared.check()
            switch status {
            case .available(let version):
                notifiedVersion = version
                presentUpdateAlert(version: version)
            case .upToDate:
                let alert = NSAlert()
                alert.messageText = AppModel.shared.localizedString("You're up to date")
                alert.informativeText = AppModel.shared.localizedString("Current version: %@", UpdateChecker.shared.currentVersion)
                NSApp.activate()
                alert.runModal()
            case .failed(let message):
                presentUpdateFailure(message)
            default:
                break
            }
        }
    }

    /// Наблюдение за статусом без SwiftUI-тела: withObservationTracking
    /// читает поля в теле, на каждое изменение перерегистрируется.
    private func observeUpdateStatus() {
        withObservationTracking {
            let checker = UpdateChecker.shared
            applyStatusItemUpdate(status: checker.status, progress: checker.downloadProgress)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                self?.observeUpdateStatus()
            }
        }
    }

    private func applyStatusItemUpdate(status: UpdateChecker.Status, progress: Double) {
        guard let button = statusItem?.button else { return }
        let symbolName: String?
        switch status {
        case .downloading: symbolName = "arrow.down.circle"
        case .installing: symbolName = "arrow.triangle.2.circlepath"
        default: symbolName = nil
        }
        if let symbolName, let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil) {
            image.isTemplate = true
            image.size = NSSize(width: 20, height: 20)
            button.image = image
            var title = ""
            if case .downloading = status {
                title = " \(Int((progress * 100).rounded(.down)))%"
            }
            button.title = title
        } else if let base = statusIcon {
            button.image = base
            button.title = ""
        } else {
            button.image = nil
            button.title = "A⇄Я"
        }
    }

    /// Завершение апдейта: баннер (или алерт-фолбэк) о том, что новая
    /// версия встала и приложение перезапустилось.
    private func announceUpdateInstalled(to version: String, from: String) {
        let title = AppModel.shared.localizedString("Update installed")
        let body = AppModel.shared.localizedString("AbubTranslate was updated to %@.", version)
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if granted {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                let request = UNNotificationRequest(identifier: "update-installed-\(version)", content: content, trigger: nil)
                try? await center.add(request)
            } else {
                let alert = NSAlert()
                alert.messageText = title
                alert.informativeText = body
                NSApp.activate()
                alert.runModal()
            }
        }
    }

    /// Фоновая находка: системный баннер, отказ в правах — алерт.
    private func announceUpdate(_ version: String) {
        guard notifiedVersion != version else { return }
        notifiedVersion = version
        let title = AppModel.shared.localizedString("New version available")
        let body = AppModel.shared.localizedString("AbubTranslate %@ is available — you have %@.", version, UpdateChecker.shared.currentVersion)
        let center = UNUserNotificationCenter.current()
        Task { @MainActor in
            let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
            if granted {
                let content = UNMutableNotificationContent()
                content.title = title
                content.body = body
                let request = UNNotificationRequest(identifier: "update-\(version)", content: content, trigger: nil)
                try? await center.add(request)
            } else {
                presentUpdateAlert(version: version)
            }
        }
    }

    private func presentUpdateAlert(version: String) {
        let alert = NSAlert()
        alert.messageText = AppModel.shared.localizedString("New version available")
        alert.informativeText = AppModel.shared.localizedString("AbubTranslate %@ is available — you have %@.", version, UpdateChecker.shared.currentVersion)
        alert.addButton(withTitle: AppModel.shared.localizedString("Download & Install"))
        alert.addButton(withTitle: AppModel.shared.localizedString("Later"))
        NSApp.activate()
        if alert.runModal() == .alertFirstButtonReturn {
            startInstall()
        }
    }

    private func presentUpdateFailure(_ message: String) {
        let alert = NSAlert()
        alert.messageText = AppModel.shared.localizedString("Update failed: %@", message)
        NSApp.activate()
        alert.runModal()
    }

    private func startInstall() {
        Task { @MainActor in
            await UpdateChecker.shared.downloadAndInstall()
            // До NSApp.terminate внутри checker доходит только успех;
            // сюда падают все неудачи — у них свой понятный текст.
            if case .failed(let message) = UpdateChecker.shared.status {
                presentUpdateFailure(message)
            }
        }
    }

    // MARK: - UNUserNotificationCenterDelegate

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        Task { @MainActor [weak self] in
            self?.startInstall()
        }
        completionHandler()
    }

    // MARK: - Diagnostic self-tests

    /// Прогон проверки обновлений без UI: `--args --update-selftest`.
    /// Лог — тот же файл, что у облачных самотестов.
    private func runUpdateSelfTest() async {
        let log = selfTestLog
        let checker = UpdateChecker.shared
        log("=== update selftest ===")
        log("current: \(checker.currentVersion)")
        let checks: [(candidate: String, current: String, want: Bool)] = [
            ("1.2", "1.1", true), ("1.1", "1.1", false), ("1.0", "1.1", false),
            ("2.0", "1.9", true), ("1.10", "1.9", true), ("1.1", "1.1.0", false),
            ("v1.2", "1.1", true), ("1.1", "0", true),
        ]
        for c in checks {
            let got = UpdateChecker.isNewer(candidate: c.candidate, than: c.current)
            log("compare \(c.candidate) > \(c.current): \(got) \(got == c.want ? "OK" : "FAIL want \(c.want)")")
        }
        let status = await checker.check()
        log("check: \(status)")
        // Реальная загрузка latest-ассета через делегат прогресса: выборка
        // ~каждые 20% + обязательный финальный 100. Установка не трогается.
        let probeURL = URL(string: "https://github.com/Abubiker/AbubTranslate/releases/latest/download/AbubTranslate.dmg")!
        let seen = ProgressSamples()
        do {
            let local = try await UpdateChecker.download(from: probeURL) { value in
                Task { @MainActor in
                    if seen.add(value) { log("download progress \(Int(value * 100))%") }
                }
            }
            let size = (try? local.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? -1
            log("download ok, size \(size)")
            try? FileManager.default.removeItem(at: local)
        } catch {
            log("download error: \(error.localizedDescription)")
        }
        log("=== end ===")
    }

    /// Буфер семплов прогресса для самотеста.
    private final class ProgressSamples: @unchecked Sendable {
        private var last = -100
        func add(_ value: Double) -> Bool {
            let percent = Int(value * 100)
            guard percent - last >= 20 || (percent >= 100 && last < 100) else { return false }
            last = percent
            return true
        }
    }

}
