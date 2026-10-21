import Foundation

/// Turns flash durations into whole display frames. Each flash is held for a whole number of
/// frames (at least `minimumFrames`) and the rounding left over is carried into the next flash, so
/// the average speed is exact and the rhythm even. The minimum itself is not carried: the timing
/// solver (Pacing.clock, `minimumFlash`) already budgets it by taking the time from elsewhere.
public struct FrameQuantizer: Sendable {
    public var frameDuration: Double
    public private(set) var carry = 0.0
    public static let minimumFrames = 2

    public init(frameDuration: Double) {
        self.frameDuration = frameDuration
    }

    public mutating func reset() { carry = 0 }

    /// Frames to hold a flash that should last `seconds`.
    public mutating func frames(for seconds: Double) -> Int {
        let minimum = Double(Self.minimumFrames) * frameDuration
        let total = max(seconds, minimum) + carry
        let frames = max(Self.minimumFrames, Int((total / frameDuration).rounded()))
        carry = max(-frameDuration, min(frameDuration, total - Double(frames) * frameDuration))
        return frames
    }
}
