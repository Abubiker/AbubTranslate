import AppKit
import Carbon.HIToolbox

/// Защита от само-триггера: restore буфера после синтетического ⌘C/V
/// поднимает changeCount с чужой картинкой — watch изображениям в буфере
/// должен пропустить это окно.
@MainActor
enum ClipboardGate {
    nonisolated(unsafe) static var suppressedUntil = Date.distantPast
}

/// Читает выделенный текст и вставляет перевод на место выделения.
///
/// Приоритетный путь — Accessibility API (`AXSelectedText`): без касания
/// буфера и поллинга, латентность десятки миллисекунд. Не все приложения
/// отдают выделение через AX (Electron-редакторы часто молчат) — для них
/// остаётся общепринятый приём: синтетический ⌘C, ожидание изменения
/// `changeCount` и обязательное восстановление прежнего буфера.
@MainActor
final class SelectionReader {
    /// Сколько ждём, пока приложение положит выделение в буфер.
    private let timeout = Duration.milliseconds(300)
    private let pollStep = Duration.milliseconds(20)
    /// AX-вызовы к зависшему приложению блокируют поток на секунды —
    /// обрываем переписку с элементом раньше фолбэка.
    private let axTimeout: Float = 0.3

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Показывает системный диалог с предложением выдать «Универсальный доступ».
    static func requestTrust() {
        // kAXTrustedCheckOptionPrompt — глобальная переменная C, для Swift 6
        // она не Sendable; ключ стабилен, берём его строковое значение.
        let options = ["AXTrustedCheckOptionPrompt": true]
        _ = AXIsProcessTrustedWithOptions(options as CFDictionary)
    }

    /// `nil` — выделения нет, нет разрешения или приложение не ответило.
    /// Буфер обмена в любом случае остаётся таким, каким был.
    func readSelection() async -> String? {
        guard Self.isTrusted else { return nil }
        if let ax = readSelectionViaAX() { return ax }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        let before = pasteboard.changeCount

        await waitHotKeyModifiersReleased()
        guard postCommandC() else { return nil }

        var waited = Duration.zero
        while waited < timeout {
            try? await Task.sleep(for: pollStep)
            waited += pollStep
            guard pasteboard.changeCount != before else { continue }
            let text = pasteboard.string(forType: .string)
            restore(saved, to: pasteboard)
            return text
        }

        // Таймаут: если буфер всё же изменился на не-строку (картинка) — восстановить
        if pasteboard.changeCount != before {
            restore(saved, to: pasteboard)
        }
        return nil
    }

    /// Быстрый путь: системный AX-элемент → focused app → focused UI
    /// element → `AXSelectedText`. Пустой/nil-ответ означает «этот клиент
    /// не отдаёт», и вызывающий падает на clipboard-путь, а не «выделения
    /// нет» — различить их снаружи нельзя.
    private func readSelectionViaAX() -> String? {
        let system = AXUIElementCreateSystemWide()
        var appRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef) == .success,
              let appRef
        else { return nil }
        let app = appRef as! AXUIElement
        AXUIElementSetMessagingTimeout(app, axTimeout)

        // Свой собственный поповер с focused-полем ввода давал бы «выделение
        // из себя же» — читаем только чужое приложение. kAXPidAttribute не
        // в Swift-оверлее ApplicationServices — константа стабильна как строка.
        var own = false
        var pidRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(app, "AXPID" as CFString, &pidRef) == .success,
           let number = pidRef as? NSNumber, number.intValue == getpid() { own = true }
        guard !own else { return nil }

        var elRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &elRef) == .success,
              let elRef
        else { return nil }
        let element = elRef as! AXUIElement

        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &value) == .success,
              let text = value as? String
        else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : text
    }

    /// Вставляет `text` на место выделения целевого приложения: пишет в
    /// буфер, шлёт ⌘V и возвращает прежний буфер обратно — перевод к
    /// моменту restore уже в документе, буфер снова «как был».
    func replaceClipboardAndPaste(_ text: String) async -> Bool {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        guard postCommand(.init(kVK_ANSI_V)) else {
            restore(saved, to: pasteboard)
            return false
        }
        try? await Task.sleep(for: .milliseconds(350))
        restore(saved, to: pasteboard)
        return true
    }

    // MARK: - Буфер обмена

    private func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        // pasteboardItems может быть nil если буфер пустой — сохраняем пустой массив, при restore не очищаем зря
        guard let items = pasteboard.pasteboardItems, !items.isEmpty else { return [] }
        return items.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        }
    }

    /// Восстанавливает безусловно (не только при "ровно +1" changeCount).
    /// Прежняя версия сверяла changeCount на +1 ровно и пропускала restore
    /// при любом отклонении — на деле это ломало restore почти всегда,
    /// когда рядом крутится менеджер буфера обмена (Mole, iBar Pro и т.п.):
    /// такие инструменты сами трогают pasteboard при каждом изменении,
    /// changeCount уходит на +2/+3 даже для нашего же ⌘C, и обещанное
    /// «буфер всегда возвращается как был» (см. README) переставало
    /// работать в самом обычном случае ради защиты от редкого — конкурентной
    /// записи от другого приложения ровно в то же окно в 300мс.
    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        ClipboardGate.suppressedUntil = Date().addingTimeInterval(1.5)
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    // MARK: - Синтетические клавиши

    /// На macOS 14+ локальный фильтр подавления — no-op, и синтетический
    /// ⌘C при физически удерживаемых модификаторах хоткея уезжает в целевое
    /// приложение как ⌥⇧C. Ждём отпускания клавиш (палец уходит с хоткея
    /// быстрее нашего окна) и только потом шлём копирование.
    private func waitHotKeyModifiersReleased() async {
        var waited = Duration.zero
        while waited < Duration.milliseconds(200) {
            let flags = CGEventSource.flagsState(.hidSystemState)
            if flags.isDisjoint(with: [.maskShift, .maskControl, .maskAlternate, .maskCommand]) { return }
            try? await Task.sleep(for: pollStep)
            waited += pollStep
        }
    }

    private func postCommandC() -> Bool { postCommand(CGKeyCode(kVK_ANSI_C)) }

    private func postCommand(_ key: CGKeyCode) -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Гасим физически зажатые модификаторы хоткея (⌥⇧), иначе в активное
        // приложение уедет ⌥⇧C вместо чистого C.
        // setLocalEventsFilterDuringSuppressionState deprecated в macOS 14, но на M-series всё ещё работает.
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }

        down.flags = .maskCommand
        up.flags = .maskCommand
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        return true
    }
}
