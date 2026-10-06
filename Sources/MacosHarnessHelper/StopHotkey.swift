import Carbon

/// Runs an action when the user presses ⌃⌥⌘., from any app.
@MainActor
final class StopHotkey {
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    /// The action the hotkey runs.
    nonisolated(unsafe) private static var action: (() -> Void)?

    init(action: @escaping () -> Void) {
        Self.action = action
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { StopHotkey.action?() }
            return noErr
        }, 1, &eventType, nil, &handler)

        let signature = "MHRN".utf8.reduce(OSType(0)) { $0 << 8 | OSType($1) }
        let id = EventHotKeyID(signature: signature, id: 1)
        RegisterEventHotKey(
            UInt32(kVK_ANSI_Period), UInt32(controlKey | optionKey | cmdKey), id,
            GetApplicationEventTarget(), 0, &hotKey
        )
    }
}
