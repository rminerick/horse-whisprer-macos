import Carbon
import Foundation

/// One Carbon hot key. Several controllers can coexist (the dictation shortcut
/// and the Escape-to-cancel key), so each only answers events for its own ID.
final class HotKeyController {
    private static let signature = OSType(0x48575752)

    private let identifier: UInt32
    private var hotKeyRef: EventHotKeyRef?
    private var eventHandlerRef: EventHandlerRef?
    private var handler: ((Bool) -> Void)?

    init(identifier: UInt32 = 1) {
        self.identifier = identifier
    }

    var isRegistered: Bool {
        hotKeyRef != nil
    }

    /// `handler` receives true when the key goes down and false when it comes up.
    @discardableResult
    func register(_ binding: HotKeyBinding, handler: @escaping (Bool) -> Void) -> Bool {
        unregister()
        self.handler = handler

        let eventSpecs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased))
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, eventRef, userData in
            guard let userData, let eventRef else { return OSStatus(eventNotHandledErr) }
            let controller = Unmanaged<HotKeyController>.fromOpaque(userData).takeUnretainedValue()
            return controller.handleEvent(eventRef)
        }, eventSpecs.count, eventSpecs, Unmanaged.passUnretained(self).toOpaque(), &eventHandlerRef)

        let hotKeyID = EventHotKeyID(signature: Self.signature, id: identifier)
        let status = RegisterEventHotKey(binding.keyCode, binding.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKeyRef)
        if status != noErr {
            unregister()
            return false
        }
        return true
    }

    func unregister() {
        if let hotKeyRef {
            UnregisterEventHotKey(hotKeyRef)
            self.hotKeyRef = nil
        }

        if let eventHandlerRef {
            RemoveEventHandler(eventHandlerRef)
            self.eventHandlerRef = nil
        }

        handler = nil
    }

    private func handleEvent(_ eventRef: EventRef) -> OSStatus {
        var eventHotKeyID = EventHotKeyID()
        let status = GetEventParameter(
            eventRef,
            EventParamName(kEventParamDirectObject),
            EventParamType(typeEventHotKeyID),
            nil,
            MemoryLayout<EventHotKeyID>.size,
            nil,
            &eventHotKeyID
        )
        // Let another controller's handler see events that are not ours.
        guard status == noErr,
              eventHotKeyID.signature == Self.signature,
              eventHotKeyID.id == identifier else {
            return OSStatus(eventNotHandledErr)
        }

        handler?(GetEventKind(eventRef) == UInt32(kEventHotKeyPressed))
        return noErr
    }
}
