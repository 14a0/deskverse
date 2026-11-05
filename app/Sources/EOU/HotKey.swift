import Carbon

/// A system-wide hotkey through Carbon. Needs no Accessibility permission.
@MainActor
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var handlers: [UInt32: () -> Void] = [:]
    private static var installed = false

    let label: String

    init?(keyCode: UInt32, modifiers: UInt32, id: UInt32, label: String, handler: @escaping () -> Void) {
        self.label = label
        Self.installHandler()
        let hotKeyID = EventHotKeyID(signature: OSType(0x454F_5530), id: id) // "EOU0"
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        guard status == noErr else { return nil }
        Self.handlers[id] = handler
    }

    private static func installHandler() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var hotKeyID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            let id = hotKeyID.id
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.handlers[id]?() } }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Shift+Command+Space first (one step from Spotlight); Control+Option+Command+Space if that is taken.
    static func registerLauncher(_ handler: @escaping () -> Void) -> HotKey? {
        let space = UInt32(kVK_Space)
        if let key = HotKey(keyCode: space, modifiers: UInt32(cmdKey | shiftKey), id: 1, label: "Shift+Command+Space", handler: handler) {
            return key
        }
        return HotKey(keyCode: space, modifiers: UInt32(cmdKey | optionKey | controlKey), id: 2,
                      label: "Control+Option+Command+Space", handler: handler)
    }
}
