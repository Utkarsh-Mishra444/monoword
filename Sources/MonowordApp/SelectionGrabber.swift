import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum TextSource: String {
    case selection = "Selection"
    case clipboard = "Clipboard"
    case service = "Services"
    case url = "Link"
    case resume = "Resumed"
    case sample = "Sample"
}

/// Gets the text he has selected in whatever app is in front.
///
/// 1. Accessibility, if allowed: ask the focused element for its selected text. No side effects.
/// 2. Accessibility, if allowed: press ⌘C on his behalf, read the clipboard, put the old clipboard back.
/// 3. Otherwise (or if nothing is selected): the clipboard as it is.
enum SelectionGrabber {

    struct Result {
        let text: String
        let source: TextSource
        /// True when Accessibility is off, so only the clipboard could be read.
        let limited: Bool
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// A ⌘C round trip is under way; a second press waits for it instead of stacking a second copy.
    private static var copying = false
    /// Bumped by every grab, so a late restore from an older round never undoes a newer one.
    private static var generation = 0

    /// Calls back on the main queue. `text` is empty when nothing could be found.
    static func grab(completion: @escaping (Result) -> Void) {
        guard isTrusted else {
            Log.app.notice("grab: no Accessibility, reading the clipboard")
            completion(Result(text: clipboardText(.general) ?? "", source: .clipboard, limited: true))
            return
        }
        if let text = accessibilitySelectedText() {
            Log.app.notice("grab: Accessibility selected text, \(text.count) chars")
            completion(Result(text: text, source: .selection, limited: false))
            return
        }
        guard !copying else { return }
        copying = true
        generation += 1
        copySelection { copied in
            copying = false
            Log.app.notice("grab: ⌘C \(copied == nil ? "copied nothing, clipboard fallback" : "copied \(copied!.count) chars", privacy: .public)")
            if let copied {
                completion(Result(text: copied, source: .selection, limited: false))
            } else {
                completion(Result(text: clipboardText(.general) ?? "", source: .clipboard, limited: false))
            }
        }
    }

    // MARK: - Accessibility

    static func accessibilitySelectedText() -> String? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement
        AXUIElementSetMessagingTimeout(element, 0.25)
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selected) == .success,
              let text = selected as? String,
              text.contains(where: { !$0.isWhitespace }) else { return nil }
        return text
    }

    // MARK: - Simulated ⌘C

    /// Presses ⌘C in the front app, waits for the clipboard to change, reads it, restores the old
    /// contents. Calls back with nil when the clipboard did not change (nothing was selected).
    static func copySelection(completion: @escaping (String?) -> Void) {
        let pasteboard = NSPasteboard.general
        let saved = snapshot(pasteboard)
        let before = pasteboard.changeCount

        // The hotkey's own modifiers (⌃⌥) are usually still down; ⌘C must arrive without them.
        waitForModifierRelease(deadline: Date().addingTimeInterval(0.6)) {
            postCommandC()
            let deadline = Date().addingTimeInterval(0.45)
            func poll() {
                if pasteboard.changeCount != before {
                    // Give the app a beat to finish writing every type, then read.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                        let text = clipboardText(pasteboard)
                        restore(saved, to: pasteboard)
                        completion(text?.contains(where: { !$0.isWhitespace }) == true ? text : nil)
                    }
                } else if Date() < deadline {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: poll)
                } else {
                    completion(nil)
                    restoreIfLate(saved, pasteboard: pasteboard, since: before, generation: generation)
                }
            }
            poll()
        }
    }

    /// A slow app may still answer the ⌘C after we gave up: for a second, put his clipboard back
    /// if that happens.
    static func restoreIfLate(_ saved: Snapshot, pasteboard: NSPasteboard, since count: Int, generation round: Int,
                              tries: Int = 20) {
        guard tries > 0, round == generation else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            guard round == generation else { return }
            if pasteboard.changeCount != count {
                restore(saved, to: pasteboard)
            } else {
                restoreIfLate(saved, pasteboard: pasteboard, since: count, generation: round, tries: tries - 1)
            }
        }
    }

    static func waitForModifierRelease(deadline: Date, then action: @escaping () -> Void) {
        let held: CGEventFlags = [.maskControl, .maskAlternate, .maskShift, .maskCommand]
        if CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty || Date() >= deadline {
            action()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) {
                waitForModifierRelease(deadline: deadline, then: action)
            }
        }
    }

    static func postCommandC() {
        let key = CGKeyCode(KeyNames.keyCode(forCommandCharacter: "c", fallback: UInt16(kVK_ANSI_C)))
        let source = CGEventSource(stateID: .privateState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: down) else { continue }
            event.flags = .maskCommand
            event.post(tap: .cghidEventTap)
        }
    }

    // MARK: - Clipboard

    static func clipboardText(_ pasteboard: NSPasteboard) -> String? {
        if let s = pasteboard.string(forType: .string), !s.isEmpty { return s }
        if let data = pasteboard.data(forType: .rtf),
           let a = NSAttributedString(rtf: data, documentAttributes: nil) { return a.string }
        if let data = pasteboard.data(forType: .html),
           let a = NSAttributedString(html: data, documentAttributes: nil) { return a.string }
        return nil
    }

    typealias Snapshot = [[(NSPasteboard.PasteboardType, Data)]]

    static func snapshot(_ pasteboard: NSPasteboard) -> Snapshot {
        (pasteboard.pasteboardItems ?? []).map { item in
            item.types.compactMap { type in item.data(forType: type).map { (type, $0) } }
        }
    }

    /// Puts a snapshot back. Marked transient (nspasteboard.org) so clipboard managers such as
    /// Maccy do not record the restore as a new entry.
    static func restore(_ snapshot: Snapshot, to pasteboard: NSPasteboard) {
        pasteboard.clearContents()
        let items: [NSPasteboardItem] = snapshot.map { pairs in
            let item = NSPasteboardItem()
            for (type, data) in pairs { item.setData(data, forType: type) }
            return item
        }
        if let first = items.first {
            first.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            pasteboard.writeObjects(items)
        }
    }

    // MARK: - Permission

    /// Adds Monoword to the Accessibility list (system prompt) and opens that settings pane.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
