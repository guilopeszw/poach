import Carbon
import Foundation
import OSLog

/// Registers a single key chord; it does not monitor arbitrary keystrokes.
/// The default is the ⌘⇧P capture shortcut. Other chords (such as Esc during a
/// countdown) use their own `id` so the shared application event handler can
/// tell them apart.
@MainActor
final class PoachHotKey {
    private static let signature: OSType = 0x506F6163
    private let logger = Logger(subsystem: "dev.poach.app", category: "HotKey")
    private let keyCode: UInt32
    private let modifiers: UInt32
    private let id: UInt32
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?
    private var action: (() -> Void)?

    init(keyCode: UInt32 = UInt32(kVK_ANSI_P), modifiers: UInt32 = UInt32(cmdKey | shiftKey), id: UInt32 = 1) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.id = id
    }

    func register(action: @escaping () -> Void) -> Bool {
        self.action = action
        if hotKey != nil { return true }
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let result = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard result == noErr, identifier.signature == PoachHotKey.signature else {
                return OSStatus(eventNotHandledErr)
            }
            // Carbon dispatches this application event on the main thread.
            return MainActor.assumeIsolated {
                let hotKey = Unmanaged<PoachHotKey>.fromOpaque(context).takeUnretainedValue()
                guard identifier.id == hotKey.id else { return OSStatus(eventNotHandledErr) }
                hotKey.action?()
                return noErr
            }
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else {
            logger.error("Hotkey event handler failed: \(status)")
            return false
        }
        let registration = RegisterEventHotKey(keyCode, modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &hotKey)
        logger.notice("Hotkey \(self.id) registration status: \(registration)")
        if registration != noErr {
            if let handler { RemoveEventHandler(handler) }
            handler = nil
            hotKey = nil
            return false
        }
        return true
    }

    /// Releases the chord so other apps receive it again. Safe to call more than once.
    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
        action = nil
    }
}
