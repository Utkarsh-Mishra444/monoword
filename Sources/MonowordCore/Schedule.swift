import Foundation

/// The reader's timetable for one text: every flash in order, as the reader shows it when the text
/// opens and plays from the first word without a pause, with how long each one is held.
///
/// It is built from the same parts the app's reader uses, in the same order (`ReaderController`'s
/// play and tick): the document is cleaned and tokenized, `ReadingSession` groups the tokens into
/// flashes, `Pacing` gives the word and pause slots, the real-speed clock is solved once over every
/// flash from the first with the ease-in and the minimum flash, and flash `i` is held
/// `Pacing.seconds(for:clock:rampStep: i)`. The settle beat before the first word is the app's
/// window behaviour, not timing, and is not part of it.
///
/// Two kinds of holds. Exact (the default): the seconds the timing code asks for, raised to the
/// minimum flash the solve budgeted for, so the whole text takes words / wpm minutes. Quantized:
/// each hold a whole number of display frames through `FrameQuantizer`, what the app's frame clock
/// shows on a 60 Hz display (and what `Monoword --render` writes to frames.txt). The quantizer
/// belongs to a display; a player with its own clock (the Claude Code plugin's terminal band) takes
/// the exact holds.
public struct Schedule: Sendable {
    public struct Flash: Equatable, Sendable {
        /// What the flash shows: its tokens joined by single spaces, as `ReadingSession.currentText`.
        public let text: String
        /// How long it is held, in seconds.
        public let seconds: Double
        /// Source words it starts: 0 for the second and later pieces of a split word, 2 for a pair.
        public let words: Int
        /// Its tokens in the document.
        public let tokens: Range<Int>
    }

    public let flashes: [Flash]
    /// Words in the text, a split word counted once (`Document.wordCount`).
    public let wordCount: Int
    /// The real-speed clock the holds were computed with.
    public let clock: Pacing.Clock
    public let timing: TimingOptions
    /// The display rate the minimum flash is counted on (`FrameQuantizer.minimumFrames` frames).
    public let frameRate: Double
    public let isQuantized: Bool

    public var total: Double { flashes.reduce(0) { $0 + $1.seconds } }

    /// The shortest hold the solve allows: two frames at `frameRate` (1/30 s at 60 Hz).
    public var minimumFlash: Double { Double(FrameQuantizer.minimumFrames) / frameRate }

    public init(document: Document, timing: TimingOptions, chunkSize: Int = ReadingSession.auto,
                frequency: FrequencyTable?, frameRate: Double = 60, quantize: Bool = false) {
        self.timing = timing
        self.frameRate = frameRate
        self.isQuantized = quantize
        wordCount = document.wordCount
        let session = ReadingSession(document: document, chunkSize: chunkSize)
        let pacing = Pacing(document: document, options: timing, frequency: frequency)
        let ranges = session.isEmpty ? [] : session.chunks(from: 0, count: .max)
        let minimum = Double(FrameQuantizer.minimumFrames) / frameRate
        let clock = pacing.clock(forWPM: timing.wpm, from: 0, flashes: ranges, rampStep: 0, minimumFlash: minimum)
        self.clock = clock
        var quantizer = FrameQuantizer(frameDuration: 1 / frameRate)
        var out: [Flash] = []
        out.reserveCapacity(ranges.count)
        for (step, range) in ranges.enumerated() {
            let interval = pacing.seconds(for: range, clock: clock, rampStep: step)
            let seconds = quantize
                ? Double(quantizer.frames(for: interval)) * quantizer.frameDuration
                : max(interval, minimum)
            let tokens = range.map { document.tokens[$0] }
            out.append(Flash(text: tokens.map(\.text).joined(separator: " "),
                             seconds: seconds,
                             words: tokens.filter { !$0.isContinuation }.count,
                             tokens: range))
        }
        flashes = out
    }

    public init(text: String, timing: TimingOptions, chunkSize: Int = ReadingSession.auto,
                frequency: FrequencyTable?, tokenizer: TokenizerOptions = .init(), frameRate: Double = 60,
                quantize: Bool = false) {
        self.init(document: Document(raw: text, options: tokenizer), timing: timing, chunkSize: chunkSize,
                  frequency: frequency, frameRate: frameRate, quantize: quantize)
    }
}
