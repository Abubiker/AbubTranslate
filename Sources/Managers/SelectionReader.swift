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
            Self.requestTrust()
            return nil
        }

        let pasteboard = NSPasteboard.general
        let saved = snapshot(of: pasteboard)
        let before = pasteboard.changeCount

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

        // Буфер не менялся — выделения не было, восстанавливать нечего.
        return nil
    }

    // MARK: - Буфер обмена

    private func snapshot(of pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) {
                    copy.setData(data, forType: type)
                }
            }
            return copy
        } ?? []
    }

    private func restore(_ items: [NSPasteboardItem], to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        guard !items.isEmpty else { return }
        pasteboard.writeObjects(items)
    }

    // MARK: - Синтетический ⌘C

    private func postCommandC() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState) else { return false }
        // Гасим физически зажатые модификаторы хоткея (⌥⇧), иначе в активное
        // приложение уедет ⌥⇧⌘C вместо чистого ⌘C.
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
