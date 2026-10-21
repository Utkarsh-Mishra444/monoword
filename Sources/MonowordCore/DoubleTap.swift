import Foundation

/// Recognises a quick double tap of one modifier key on its own (the right ⌘ in the app): two short
/// presses close together with nothing else pressed. A press held long, any other key or modifier
/// in between, or a slow second tap cancels it, so shortcuts that use the key never fire it.
/// Time-free state machine: the app feeds it key events with their timestamps.
public struct DoubleTapDetector: Sendable {
    /// Longest press that still counts as a tap.
    public var maxTapDuration: TimeInterval = 0.30
    /// Longest pause between releasing the first tap and pressing the second.
    public var maxGap: TimeInterval = 0.35

    private var pressedAt: TimeInterval?
    private var lastTapEnd: TimeInterval?
    private var spoiled = false

    public init() {}

    /// The watched key went down or up. `othersHeld`: any other modifier is down at that moment.
    /// Returns true on the release that completes a double tap.
    public mutating func key(down: Bool, othersHeld: Bool, at time: TimeInterval) -> Bool {
        if down {
            if othersHeld { reset(); return false }
            if let end = lastTapEnd, time - end > maxGap { lastTapEnd = nil }
            pressedAt = time
            spoiled = false
            return false
        }
        guard let start = pressedAt else { return false }
        pressedAt = nil
        if spoiled || othersHeld || time - start > maxTapDuration {
            reset()
            return false
        }
        if let end = lastTapEnd, start - end <= maxGap {
            reset()
            return true
        }
        lastTapEnd = time
        return false
    }

    /// Any other key or modifier was pressed: whatever was in progress was part of a shortcut.
    public mutating func interrupted() {
        if pressedAt != nil { spoiled = true }
        lastTapEnd = nil
    }

    public mutating func reset() {
        pressedAt = nil
        lastTapEnd = nil
        spoiled = false
    }
}
