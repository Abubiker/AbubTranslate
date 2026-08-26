import SwiftUI
@preconcurrency import Translation

@main
struct TranslatorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel.shared

    init() {
        AppModel.shared.startHotKeys()
    }

    var body: some Scene {
        Settings {
            SettingsView()
                .environment(model)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem?
    private let popover = NSPopover()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "AbubTranslateStatusItem"
        item.isVisible = true
        if let button = item.button {
            if let icon = NSImage(named: "StatusIcon") {
                icon.isTemplate = true
                icon.size = NSSize(width: 20, height: 20)
                button.image = icon
            } else if let symbol = NSImage(systemSymbolName: "translate", accessibilityDescription: "AbubTranslate") {
                button.image = symbol
            } else {
                button.title = "A⇄Я"
            }
            if button.image == nil && button.title.isEmpty {
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
        let settings = menu.addItem(
            withTitle: String(localized: "Settings…"),
            action: #selector(openSettingsFromMenu),
            keyEquivalent: ","
        )
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(
            withTitle: String(localized: "Quit AbubTranslate"),
            action: #selector(quitFromMenu),
            keyEquivalent: "q"
        )
        quit.target = self

        item.menu = menu
        button.performClick(nil)
        item.menu = nil
    }

    @objc private func quitFromMenu() {
        NSApp.terminate(nil)
    }

    @objc private func openSettingsFromMenu() {
        NSApp.activate(ignoringOtherApps: true)
        // Селектор SwiftUI-сцены Settings; на macOS 13 назывался иначе.
        if !NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
        }
        // Окно сцены Settings появляется на следующем витке цикла событий,
        // поэтому поднимаем его отдельно — иначе оно останется позади.
        DispatchQueue.main.async {
            NSApp.windows
                .first { $0.styleMask.contains(.titled) && $0.isVisible }?
                .makeKeyAndOrderFront(nil)
        }
    }

    func togglePopover() {
        guard let button = statusItem?.button else { return }
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        NSApp.activate(ignoringOtherApps: true)
        if let window = button.window, window.screen != nil {
            // Обычный путь: поповер из иконки в статус-баре.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        } else {
            // Статус-итем спрятан (переполненный меню-бар или менеджер иконок) —
            // анкерим поповер к невидимой панели под меню-баром активного экрана.
            showPopoverViaFallbackAnchor()
        }
    }

    private var fallbackAnchorPanel: NSPanel?

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
        let x = min(
            max(screen.visibleFrame.minX + halfWidth + margin, mouse.x),
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
    }

}
