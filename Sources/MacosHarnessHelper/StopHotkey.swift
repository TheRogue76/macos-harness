import Carbon

/// ⌃⌥⌘. stops every agent, from anywhere. A Carbon hotkey needs no Input Monitoring permission.
@MainActor
final class StopHotkey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// The Carbon callback is a C function; it reaches the Swift closure through this.
    nonisolated(unsafe) private static var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        Self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { StopHotkey.action?() }
            return noErr
        }, 1, &eventType, nil, &handler)

        let id = EventHotKeyID(signature: OSType(0x4D48_524E), id: 1)  // "MHRN"
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Period), UInt32(controlKey | optionKey | cmdKey), id,
            GetApplicationEventTarget(), 0, &hotKey
        )
    }
}
