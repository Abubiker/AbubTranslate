import AppKit
import Carbon.HIToolbox

/// Читает выделенный текст в активном приложении.
///
/// Синхронного API для этого в macOS нет, поэтому используется общепринятый
/// приём: синтетический ⌘C, ожидание изменения `changeCount` и обязательное
/// восстановление прежнего буфера обмена.
@MainActor
final class SelectionReader {
    /// Сколько ждём, пока приложение положит выделение в буфер.
    private let timeout = Duration.milliseconds(300)
    private let pollStep = Duration.milliseconds(20)

    /// Системный диалог запроса доступа вызывается только со старта приложения
    /// (AppDelegate) и с кнопки в настройках: нажатие хоткея не должно
    /// порождать модальных окон — пользователь ждёт перевода, а не опроса.
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
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    // MARK: - Синтетический ⌘C

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

    private func postCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Гасим физически зажатые модификаторы хоткея (⌥⇧), иначе в активное
        // приложение уедет ⌥⇧⌘C вместо чистого ⌘C.
        // setLocalEventsFilterDuringSuppressionState deprecated в macOS 14, но на M-series всё ещё работает.
        // Для M-only (arm64) оставляем как есть, подавляем warning.
        if #available(macOS 14.0, *) {
            // no-op, API deprecated but still functional on Apple Silicon
        }
        source.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let key = CGKeyCode(kVK_ANSI_C)
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
