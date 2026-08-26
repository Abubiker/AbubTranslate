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
}
