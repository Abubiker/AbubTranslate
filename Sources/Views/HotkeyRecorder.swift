import AppKit
import Carbon.HIToolbox
import SwiftUI

struct HotkeyBinding: Equatable, Codable {
    var keyCode: UInt32
    var modifiers: UInt32

    static let defaultTranslate = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_T),
        modifiers: UInt32(optionKey | shiftKey)
    )
    static let defaultSpeak = HotkeyBinding(
        keyCode: UInt32(kVK_ANSI_Y),
        modifiers: UInt32(optionKey | shiftKey)
    )

    static func load(slot: HotKeyManager.Slot) -> HotkeyBinding {
        switch slot {
        case .translate:
            return load(key: "hotkey.translate", fallback: .defaultTranslate)
        case .speak:
            return load(key: "hotkey.speak", fallback: .defaultSpeak)
        }
    }

    func save(slot: HotKeyManager.Slot) {
        let key: String
        switch slot {
        case .translate: key = "hotkey.translate"
        case .speak: key = "hotkey.speak"
        }
        let defaults = UserDefaults.standard
        defaults.set(Int(keyCode), forKey: key + ".keyCode")
        defaults.set(Int(modifiers), forKey: key + ".modifiers")
    }

    private static func load(key: String, fallback: HotkeyBinding) -> HotkeyBinding {
        let defaults = UserDefaults.standard
        guard
            defaults.object(forKey: key + ".keyCode") != nil,
            defaults.object(forKey: key + ".modifiers") != nil
        else { return fallback }
        return HotkeyBinding(
            keyCode: UInt32(defaults.integer(forKey: key + ".keyCode")),
            modifiers: UInt32(defaults.integer(forKey: key + ".modifiers"))
        )
    }

    /// Строка вида "⌥⇧T" для показа в настройках.
    var displayString: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        result += keyGlyph
        return result
    }

    private var keyGlyph: String {
        // Виртуальные коды → физическая латинская буква/символ,
        // независимо от текущей раскладки.
        let table: [UInt32: String] = [
            UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C",
            UInt32(kVK_ANSI_D): "D", UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F",
            UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H", UInt32(kVK_ANSI_I): "I",
            UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
            UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O",
            UInt32(kVK_ANSI_P): "P", UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R",
            UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T", UInt32(kVK_ANSI_U): "U",
            UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
            UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
            UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2",
            UInt32(kVK_ANSI_3): "3", UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5",
            UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7", UInt32(kVK_ANSI_8): "8",
            UInt32(kVK_ANSI_9): "9",
            UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥",
            UInt32(kVK_Escape): "Esc",
        ]
        return table[keyCode] ?? "?"
    }
}

struct HotkeyRecorder: View {
    let title: String
    let slot: HotKeyManager.Slot
    /// `false` — комбинация занята, запись откатывается на прежнюю.
    var onChange: (HotkeyBinding) -> Bool

    @State private var binding: HotkeyBinding = .defaultTranslate
    @State private var isRecording = false
    @State private var hasConflict = false
    @State private var monitor: Any?

    var body: some View {
        HStack(alignment: .top, spacing: DSTokens.md) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 140, alignment: .leading)
                .padding(.top, 6)
            VStack(alignment: .leading, spacing: DSTokens.xs) {
                Button {
                    isRecording ? cancelRecording() : startRecording()
                } label: {
                    Text(isRecording ? String(localized: "Press keys…") : binding.displayString)
                        .font(.system(size: DSTokens.labelSize, weight: .medium))
                        .frame(minWidth: 96)
                }
                .buttonStyle(.bordered)
                .tint(isRecording ? .orange : .accentColor)
                .foregroundStyle(isRecording ? .orange : .primary)

                if hasConflict {
                    Label(
                        String(localized: "That shortcut is taken by another app"),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { binding = HotkeyBinding.load(slot: slot) }
        .onDisappear { cancelRecording() }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            handleEvent(event)
            return nil
        }
    }

    private func cancelRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    private func handleEvent(_ event: NSEvent) {
        guard event.type == .keyDown else { return }
        // Esc — отмена записи.
        if event.keyCode == UInt16(kVK_Escape) {
            cancelRecording()
            return
        }
        // NSEvent-модификаторы → Carbon-биты для RegisterEventHotKey.
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var carbonMods: UInt32 = 0
        if flags.contains(.command) { carbonMods |= UInt32(cmdKey) }
        if flags.contains(.shift) { carbonMods |= UInt32(shiftKey) }
        if flags.contains(.option) { carbonMods |= UInt32(optionKey) }
        if flags.contains(.control) { carbonMods |= UInt32(controlKey) }
        guard carbonMods != 0 else {
            // Модификатор без основной клавиши — игнорируем.
            return
        }
        let newBinding = HotkeyBinding(
            keyCode: UInt32(event.keyCode),
            modifiers: carbonMods
        )
        let previous = binding
        newBinding.save(slot: slot)
        if onChange(newBinding) {
            binding = newBinding
            hasConflict = false
        } else {
            // Регистрация не прошла — возвращаем прежнюю рабочую комбинацию.
            previous.save(slot: slot)
            _ = onChange(previous)
            binding = previous
            hasConflict = true
        }
        cancelRecording()
    }
}
