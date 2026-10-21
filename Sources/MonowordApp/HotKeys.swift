import AppKit
import Carbon.HIToolbox

/// System-wide shortcuts through Carbon's RegisterEventHotKey: works in every app and needs no
/// permission (unlike an event tap, which needs Input Monitoring).
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var actions: [UInt32: () -> Void] = [:]
    private var handlerInstalled = false
    private static let signature: OSType = 0x53505244  // 'SPRD'

    /// Registers `shortcut` under `id`, replacing what was there. Returns false if the system refused
    /// (usually: another app already owns that combination).
    @discardableResult
    func register(id: UInt32, shortcut: Shortcut?, action: @escaping () -> Void) -> Bool {
        unregister(id: id)
        guard let shortcut else { return true }
        installHandlerIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.modifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        actions[id] = action
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs.removeValue(forKey: id) { UnregisterEventHotKey(ref) }
        actions.removeValue(forKey: id)
    }

    func unregisterAll() {
        for id in Array(refs.keys) { unregister(id: id) }
    }

    fileprivate func fire(id: UInt32) {
        actions[id]?()
    }

    private func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr, hotKeyID.signature == HotKeyCenter.signature else { return OSStatus(eventNotHandledErr) }
            let id = hotKeyID.id
            DispatchQueue.main.async { HotKeyCenter.shared.fire(id: id) }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

/// Human names for virtual key codes, using the current keyboard layout for character keys.
enum KeyNames {
    static let special: [UInt32: String] = [
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "↩", UInt32(kVK_Tab): "⇥", UInt32(kVK_Escape): "⎋",
        UInt32(kVK_Delete): "⌫", UInt32(kVK_ForwardDelete): "⌦", UInt32(kVK_LeftArrow): "←",
        UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_Home): "↖", UInt32(kVK_End): "↘", UInt32(kVK_PageUp): "⇞", UInt32(kVK_PageDown): "⇟",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
        UInt32(kVK_F13): "F13", UInt32(kVK_F14): "F14", UInt32(kVK_F15): "F15", UInt32(kVK_F16): "F16",
        UInt32(kVK_F17): "F17", UInt32(kVK_F18): "F18", UInt32(kVK_F19): "F19", UInt32(kVK_F20): "F20",
    ]

    static func name(for keyCode: UInt32) -> String {
        if let s = special[keyCode] { return s }
        if let s = translate(keyCode: UInt16(keyCode), modifierState: 0), !s.isEmpty,
           !s.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return s.uppercased()
        }
        return "#\(keyCode)"
    }

    /// The character a key produces in the current layout (modifierState is Carbon modifiers >> 8).
    static func translate(keyCode: UInt16, modifierState: UInt32) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue()
                ?? TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue(),
              let raw = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        return data.withUnsafeBytes { buffer -> String? in
            guard let layout = buffer.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return nil }
            var deadKeys: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var length = 0
            let status = UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), modifierState,
                                        UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysMask),
                                        &deadKeys, chars.count, &length, &chars)
            guard status == noErr else { return nil }
            return String(utf16CodeUnits: chars, count: length)
        }
    }

    /// The key that types `character` together with ⌘ in the current layout (layouts such as
    /// "Dvorak - QWERTY ⌘" move command shortcuts). Falls back to the ANSI position.
    static func keyCode(forCommandCharacter character: String, fallback: UInt16) -> UInt16 {
        let commandState = UInt32(cmdKey >> 8) & 0xFF
        for code in UInt16(0)..<UInt16(128) {
            if translate(keyCode: code, modifierState: commandState)?.lowercased() == character { return code }
        }
        return fallback
    }
}
