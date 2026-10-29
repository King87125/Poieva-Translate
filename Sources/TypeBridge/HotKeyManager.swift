import TypeBridgeCore
import AppKit
import Carbon

enum ShortcutAction: UInt32, CaseIterable, Identifiable {
    case input = 1
    case selection = 2

    var id: UInt32 { rawValue }
    var title: String { self == .input ? L10n.tr("翻译并替换") : L10n.tr("翻译预览") }
}

struct KeyboardShortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32
    var character: String

    var label: String {
        var result = ""
        if modifiers & UInt32(controlKey) != 0 { result += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { result += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { result += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { result += "⌘" }
        return result + character
    }

    var readableLabel: String {
        let names = ["↩": "Return", "⇥": "Tab", "⌫": "Delete", "←": "←", "→": "→", "↓": "↓", "↑": "↑"]
        return (Self.modifierNames(modifiers) + [names[character] ?? character]).joined(separator: " + ")
    }

    static func modifierPreview(_ event: NSEvent) -> String {
        let names = modifierNames(carbonModifiers(event.modifierFlags))
        return names.isEmpty ? L10n.tr("请按下你想用的快捷键") : names.joined(separator: " + ") + " + …"
    }

    private static func modifierNames(_ modifiers: UInt32) -> [String] {
        var names: [String] = []
        if modifiers & UInt32(controlKey) != 0 { names.append("Control") }
        if modifiers & UInt32(optionKey) != 0 { names.append("Option") }
        if modifiers & UInt32(shiftKey) != 0 { names.append("Shift") }
        if modifiers & UInt32(cmdKey) != 0 { names.append("Command") }
        return names
    }

    private static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var result: UInt32 = 0
        if flags.contains(.command) { result |= UInt32(cmdKey) }
        if flags.contains(.control) { result |= UInt32(controlKey) }
        if flags.contains(.option) { result |= UInt32(optionKey) }
        if flags.contains(.shift) { result |= UInt32(shiftKey) }
        return result
    }

    static let inputDefault = Self(keyCode: UInt32(kVK_Return), modifiers: UInt32(controlKey | optionKey), character: "↩")
    static let selectionDefault = Self(keyCode: UInt32(kVK_ANSI_D), modifiers: UInt32(controlKey | optionKey), character: "D")

    init(keyCode: UInt32, modifiers: UInt32, character: String) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.character = character
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let functionKeys: [UInt16: String] = [
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10",
            103: "F11", 111: "F12", 105: "F13", 107: "F14", 113: "F15", 106: "F16", 64: "F17", 79: "F18", 80: "F19", 90: "F20"
        ]
        guard !flags.intersection([.command, .control, .option]).isEmpty || functionKeys[event.keyCode] != nil else { return nil }
        let special: [UInt16: String] = [36: "↩", 48: "⇥", 49: L10n.tr("空格"), 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        guard let key = functionKeys[event.keyCode] ?? special[event.keyCode] ?? event.charactersIgnoringModifiers?.uppercased(), !key.isEmpty else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: Self.carbonModifiers(flags), character: key)
    }
}

@MainActor
final class HotKeyManager {
    private var references: [ShortcutAction: EventHotKeyRef] = [:]
    private var handler: EventHandlerRef?
    var onTrigger: ((ShortcutAction) -> Void)?

    init() {
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var identifier = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &identifier)
            guard status == noErr, let action = ShortcutAction(rawValue: identifier.id) else { return OSStatus(eventNotHandledErr) }
            let manager = Unmanaged<HotKeyManager>.fromOpaque(userData).takeUnretainedValue()
            Task { @MainActor in manager.onTrigger?(action) }
            return noErr
        }, 1, &specification, Unmanaged.passUnretained(self).toOpaque(), &handler)
    }

    func register(_ shortcut: KeyboardShortcut, for action: ShortcutAction) throws {
        var reference: EventHotKeyRef?
        let identifier = EventHotKeyID(signature: 0x54594252, id: action.rawValue)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, identifier, GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, let reference else { throw NSError(domain: "TypeBridge.Shortcuts", code: Int(status), userInfo: [NSLocalizedDescriptionKey: L10n.tr("\(shortcut.readableLabel) 已被其他功能或应用占用，请换一组。")] ) }
        if let previous = references[action] { UnregisterEventHotKey(previous) }
        references[action] = reference
    }

    func shutdown() {
        suspend()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    func suspend() {
        for reference in references.values { UnregisterEventHotKey(reference) }
        references.removeAll()
    }
}
