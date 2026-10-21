import AppKit
import ApplicationServices
import Carbon.HIToolbox
import MonowordCore

/// Watches the keyboard for a double tap of the right ⌘ alone. Seeing other apps' key events needs
/// the Accessibility permission (the same one selection reading uses); until it is granted the
/// monitor is installed but hears nothing, and it is re-installed the moment the permission arrives.
final class ModifierTapMonitor {
    static let shared = ModifierTapMonitor()

    var onDoubleTap: (() -> Void)?
    private(set) var isEnabled = false

    private var detector = DoubleTapDetector()
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var trustTimer: Timer?
    private var installedWhileTrusted = false

    // Device-dependent bits of NSEvent.modifierFlags (IOLLEvent.h: NX_DEVICELCMDKEYMASK and
    // NX_DEVICERCMDKEYMASK) tell the two ⌘ keys apart.
    private static let leftCommandBit: UInt = 0x08
    private static let rightCommandBit: UInt = 0x10

    /// Clicks and scrolls count as "something else pressed": ⌘-click twice is not a double tap.
    private static let watched: NSEvent.EventTypeMask = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown,
                                                         .otherMouseDown, .scrollWheel]
    private var pressedAt: TimeInterval?

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        if enabled {
            install()
            let t = Timer(timeInterval: 2, repeats: true) { [weak self] _ in self?.checkTrust() }
            RunLoop.main.add(t, forMode: .common)
            trustTimer = t
        } else {
            trustTimer?.invalidate()
            trustTimer = nil
            remove()
        }
    }

    private func checkTrust() {
        if AXIsProcessTrusted() != installedWhileTrusted { install() }
    }

    private func install() {
        remove()
        installedWhileTrusted = AXIsProcessTrusted()
        // Without Accessibility the global monitor may still see modifier changes but not the keys
        // pressed with them, so ⌘C, ⌘V would look like a double tap: listen only once trusted.
        if installedWhileTrusted {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: Self.watched) { [weak self] e in
                self?.handle(e)
            }
        }
        // Events aimed at Monoword's own windows (the reader panel) skip the global monitor.
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: Self.watched) { [weak self] e in
            self?.handle(e)
            return e
        }
        Log.app.notice("right ⌘ monitor installed, trusted=\(self.installedWhileTrusted)")
    }

    /// True when a key or click happened within the last `seconds` (system-wide counters).
    /// Replaceable so the self-test does not depend on what the keyboard is doing while it runs.
    static var keyOrClickSince: (TimeInterval) -> Bool = { seconds in
        let types: [CGEventType] = [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        return types.contains { CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: $0) < seconds }
    }

    private func remove() {
        if let m = globalMonitor { NSEvent.removeMonitor(m) }
        if let m = localMonitor { NSEvent.removeMonitor(m) }
        globalMonitor = nil
        localMonitor = nil
        detector.reset()
    }

    /// Feeds one event to the detector; internal so the self-test can drive it.
    func handle(_ event: NSEvent) {
        switch event.type {
        case .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel:
            detector.interrupted()
        case .flagsChanged:
            guard event.keyCode == UInt16(kVK_RightCommand) else {
                detector.interrupted()
                return
            }
            let raw = event.modifierFlags.rawValue
            // Some virtual keyboards (Screen Sharing, remappers) leave out the device bits.
            let hasDeviceBits = raw & (Self.leftCommandBit | Self.rightCommandBit) != 0
            let down = hasDeviceBits ? raw & Self.rightCommandBit != 0 : event.modifierFlags.contains(.command)
            let others = raw & Self.leftCommandBit != 0
                || !event.modifierFlags.intersection([.shift, .option, .control, .function]).isEmpty
            if down {
                pressedAt = event.timestamp
            } else if let start = pressedAt, Self.keyOrClickSince(event.timestamp - start) {
                // A key the system consumed (⌘Tab, ⌘Space) never reaches the monitor; the event
                // source still counts it.
                detector.interrupted()
            }
            if detector.key(down: down, othersHeld: others, at: event.timestamp) {
                Log.app.notice("right ⌘ double tap")
                onDoubleTap?()
            }
        default:
            break
        }
    }
}
