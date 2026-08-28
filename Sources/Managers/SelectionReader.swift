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

    /// Системный диалог показываем один раз за запуск: без этого каждое
    /// нажатие хоткея при отсутствии разрешения открывает новое окно запроса.
    private var didPrompt = false

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
        guard Self.isTrusted else {
            if !didPrompt {
                didPrompt = true
                Self.requestTrust()
            }
            return nil
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        let savedChangeCount = pasteboard.changeCount
        let before = pasteboard.changeCount

        guard postCommandC() else { return nil }

        var waited = Duration.zero
        while waited < timeout {
            try? await Task.sleep(for: pollStep)
            waited += pollStep
            guard pasteboard.changeCount != before else { continue }
            // Проверяем что буфер изменился именно нашим ⌘C, а не чужим приложением между снимком и чтением:
            // если changeCount уже снова ушёл дальше — кто-то другой писал, не восстанавливаем вслепую
            let text = pasteboard.string(forType: .string)
            // Только если буфер всё ещё тот что мы получили — восстанавливаем
            restore(saved, to: pasteboard, expectedChangeCount: pasteboard.changeCount, beforeCount: before, savedCount: savedChangeCount)
            // Если это была картинка (text == nil) — всё равно вернули буфер и вернём nil (нет выделения)
            return text
        }

        // Таймаут: если буфер всё же изменился на не-строку (картинка) — восстановить
        if pasteboard.changeCount != before {
            restore(saved, to: pasteboard, expectedChangeCount: pasteboard.changeCount, beforeCount: before, savedCount: savedChangeCount)
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

    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard, expectedChangeCount: Int, beforeCount: Int, savedCount: Int) {
        // Только ровно +1 — это наш ⌘C. +2 и дальше значит кто-то ещё писал после нас — не затираем чужое.
        // savedCount не используется отдельно: before уже равен savedCount на момент снимка.
        _ = savedCount
        guard expectedChangeCount == beforeCount + 1 else { return }
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    // MARK: - Синтетический ⌘C

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
