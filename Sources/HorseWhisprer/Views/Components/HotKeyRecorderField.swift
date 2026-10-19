import AppKit
import Carbon
import SwiftUI

struct HotKeyRecorderField: NSViewRepresentable {
    let binding: HotKeyBinding
    let onRecord: (HotKeyBinding) -> Void

    func makeNSView(context: Context) -> HotKeyRecorderTextField {
        let field = HotKeyRecorderTextField()
        field.onRecord = onRecord
        field.updateDisplay(binding: binding)
        return field
    }

    func updateNSView(_ nsView: HotKeyRecorderTextField, context: Context) {
        nsView.onRecord = onRecord
        nsView.updateDisplay(binding: binding)
    }
}

final class HotKeyRecorderTextField: NSTextField {
    var onRecord: ((HotKeyBinding) -> Void)?

    private var currentBinding: HotKeyBinding = .defaultBinding
    private var isRecordingShortcut = false

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isEditable = false
        isBordered = true
        drawsBackground = true
        isBezeled = true
        focusRingType = .default
        alignment = .center
        font = .systemFont(ofSize: 13, weight: .medium)
        lineBreakMode = .byTruncatingTail
        setAccessibilityLabel("Dictation shortcut. Click, then press the new shortcut.")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var acceptsFirstResponder: Bool {
        true
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted {
            isRecordingShortcut = true
            stringValue = "Type shortcut"
        }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned {
            isRecordingShortcut = false
            stringValue = currentBinding.displayString
        }
        return resigned
    }

    override func keyDown(with event: NSEvent) {
        guard isRecordingShortcut else {
            super.keyDown(with: event)
            return
        }

        if event.keyCode == UInt16(kVK_Escape) {
            window?.makeFirstResponder(nil)
            return
        }

        guard let binding = Self.binding(from: event) else {
            NSSound.beep()
            stringValue = "Use modifiers + key"
            return
        }

        currentBinding = binding
        stringValue = binding.displayString
        onRecord?(binding)
        window?.makeFirstResponder(nil)
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        false
    }

    func updateDisplay(binding: HotKeyBinding) {
        currentBinding = binding
        if !isRecordingShortcut {
            stringValue = binding.displayString
        }
    }

    private static func binding(from event: NSEvent) -> HotKeyBinding? {
        let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let carbonModifiers = carbonModifiers(from: modifiers)
        let binding = HotKeyBinding(keyCode: UInt32(event.keyCode), carbonModifiers: carbonModifiers)
        return binding.isValid ? binding : nil
    }

    private static func carbonModifiers(from modifiers: NSEvent.ModifierFlags) -> UInt32 {
        var carbonModifiers: UInt32 = 0

        if modifiers.contains(.control) {
            carbonModifiers |= UInt32(controlKey)
        }

        if modifiers.contains(.option) {
            carbonModifiers |= UInt32(optionKey)
        }

        if modifiers.contains(.shift) {
            carbonModifiers |= UInt32(shiftKey)
        }

        if modifiers.contains(.command) {
            carbonModifiers |= UInt32(cmdKey)
        }

        return carbonModifiers
    }
}
