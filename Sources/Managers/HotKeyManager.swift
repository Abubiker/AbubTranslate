import AppKit
import Carbon.HIToolbox

/// Глобальные хоткеи через Carbon RegisterEventHotKey.
/// Виртуальные коды клавиш → не зависят от раскладки;
/// Caps Lock не входит в модификаторы и на хоткей не влияет.
final class HotKeyManager: @unchecked Sendable {
    enum Slot: Int {
        case translate
        case speak
    }

    var onKeyDown: ((Slot) -> Void)?

    private var hotKeyRefs: [Slot: EventHotKeyRef] = [:]
    private var eventHandler: EventHandlerRef?
    private let lock = NSLock()

    init() {}

    deinit {
        // Снять все хоткеи и хендлер — иначе останется passUnretained указатель на мёртвый объект
        for (_, ref) in hotKeyRefs {
            UnregisterEventHotKey(ref)
        }
        hotKeyRefs.removeAll()
        if let handler = eventHandler {
            RemoveEventHandler(handler)
        }
    }

    /// `false` — комбинация занята другим приложением либо системой.
    /// Возвращать статус обязательно: молчаливый провал регистрации выглядит
    /// как «хоткей просто не работает» и не поддаётся диагностике.
    @discardableResult
    func register(slot: Slot, keyCode: UInt32, modifiers: UInt32) -> Bool {
        lock.lock(); defer { lock.unlock() }
        installEventHandlerIfNeeded()
        unregisterLocked(slot: slot)
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(
            keyCode,
            modifiers,
            EventHotKeyID(signature: OSType(0x41425452), id: UInt32(slot.rawValue) + 1),
            GetApplicationEventTarget(),
            0,
            &ref
        )
        guard status == noErr, let ref else { return false }
        hotKeyRefs[slot] = ref
        return true
    }

    func unregister(slot: Slot) {
        lock.lock(); defer { lock.unlock() }
        unregisterLocked(slot: slot)
    }

    private func unregisterLocked(slot: Slot) {
        if let ref = hotKeyRefs[slot] {
            UnregisterEventHotKey(ref)
            hotKeyRefs[slot] = nil
        }
    }

    private func installEventHandlerIfNeeded() {
        guard eventHandler == nil else { return }
        var eventType = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard),
            eventKind: UInt32(kEventHotKeyPressed)
        )
        // passUnretained — не ретайнит self, deinit снимет хендлер
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData else { return noErr }
                let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
                var hotKeyID = EventHotKeyID()
                guard
                    let event,
                    GetEventParameter(
                        event,
                        EventParamName(kEventParamDirectObject),
                        EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size,
                        nil,
                        &hotKeyID
                    ) == noErr
                else { return noErr }
                guard let slot = Slot(rawValue: Int(hotKeyID.id) - 1) else { return noErr }
                DispatchQueue.main.async {
                    manager.onKeyDown?(slot)
                }
                return noErr
            },
            1,
            &eventType,
            context,
            &eventHandler
        )
    }
}
