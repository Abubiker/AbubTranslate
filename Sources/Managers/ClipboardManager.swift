import AppKit

@MainActor
final class ClipboardManager {
    func readText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    func writeText(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private var watchTimer: Timer?
    private var lastChangeCount = 0

    /// Наблюдатель «в буфере появилась картинка»: опрос changeCount —
    /// единственный способ не трогая буфер узнать о записи от другого
    /// приложения. Порог в 0.7с — не гонять main-цикл вхолостую.
    func watchImages(onImage: @escaping @MainActor () -> Void) {
        guard watchTimer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        let timer = Timer(timeInterval: 0.7, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let pasteboard = NSPasteboard.general
                let count = pasteboard.changeCount
                guard count != self.lastChangeCount else { return }
                self.lastChangeCount = count
                guard Date() >= ClipboardGate.suppressedUntil else { return }
                guard ImageOCRManager.hasImage(pasteboard) else { return }
                onImage()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        watchTimer = timer
    }

    /// Сброс счётчика после собственного чтения: restore SelectionReader
    /// поднимает changeCount сам, watch не должен на это реагировать даже
    /// вне окна ClipboardGate.
    func noteOwnChange() {
        lastChangeCount = NSPasteboard.general.changeCount
    }
}
