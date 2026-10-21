import Foundation

public struct TimingOptions: Equatable, Sendable {
    /// Words per minute. With `realSpeed` (the default) this is the real rate: a whole text takes
    /// words / wpm minutes, pauses included. Without it, an ordinary word gets 60 / wpm seconds and
    /// pauses add time on top.
    public var wpm: Double
    /// The speed setting counts pauses (true), or only the words (false).
    public var realSpeed: Bool
    /// Scales the extra time at commas, sentence ends and paragraphs. 0 = none, 1 = normal, 2 = long.
    public var punctuationPause: Double
    /// Give long words, numbers and links a little more time.
    public var lengthPause: Bool
    /// Ease in over the first few words after starting or resuming.
    public var rampUp: Bool
    /// Research-based pacing (docs/PACING.md): rarer and longer words get more time, common short
    /// ones less, numbers by their digits; averaged back to the chosen speed.
    public var adaptive: Bool

    public init(wpm: Double = 400, punctuationPause: Double = 1, lengthPause: Bool = true, rampUp: Bool = true,
                adaptive: Bool = false, realSpeed: Bool = true) {
        self.wpm = wpm
        self.realSpeed = realSpeed
        self.punctuationPause = punctuationPause
        self.lengthPause = lengthPause
        self.rampUp = rampUp
        self.adaptive = adaptive
    }
}

/// How long each token of one document stays on screen.
///
/// A token's time is `base × word slots + pause`. The word slots come from the word itself (1 for an
/// ordinary word; adaptive pacing normalises them to average 1) and the pause from the punctuation
/// or line break after it: `max(base × pause slots, floor)`, since the time to wrap up a sentence
/// does not shrink when the words go faster. With real speed (the default) `base` is solved so the
/// whole text, pauses and ease-in included, takes exactly words / wpm minutes; the words run
/// faster than the setting to make room for the pauses. See docs/PACING.md.
public struct Pacing: Sendable {
    /// Word slots per token.
    public let slots: [Double]
    /// Pause slots per token (already scaled by the punctuation setting).
    public let pauseSlots: [Double]
    /// Minimum pause per token, in seconds.
    public let pauseFloors: [Double]
    public let options: TimingOptions
    /// Per token: 1 if it starts a source word (a split word counts once), for the real-speed target.
    private let wordStarts: [Int]

    /// Words that ease in after a start or resume.
    public static let rampWords = 5
    /// With real speed the words run at most this many times faster than the setting; past that the
    /// pauses shrink instead.
    public static let maxWordSpeedup = 2.5

    public init(document: Document, options: TimingOptions, frequency: FrequencyTable? = nil) {
        self.options = options
        wordStarts = document.tokens.map { $0.isContinuation ? 0 : 1 }
        let tokens = document.tokens
        let pf = max(0, options.punctuationPause)
        pauseSlots = tokens.map { Self.pauseSlot($0.pause) * pf }
        pauseFloors = tokens.map { Self.pauseFloor($0.pause) * min(1, pf) }
        if options.adaptive {
            slots = Self.adaptiveSlots(document: document, frequency: frequency)
        } else {
            slots = tokens.map { Self.classicSlot($0, lengthPause: options.lengthPause) }
        }
    }

    // MARK: - Time

    /// The two numbers that turn slots into seconds at one speed.
    public struct Clock: Equatable, Sendable {
        /// Seconds per word slot.
        public let base: Double
        /// Multiplies every pause (slots and floors). 1 unless the pauses had to give way.
        public let pauseScale: Double
        /// Set when the speed asked for cannot be reached on this text with flashes no shorter than
        /// the minimum: the highest real speed that can (words per minute).
        public let reachableWPM: Double?

        public init(base: Double, pauseScale: Double, reachableWPM: Double? = nil) {
            self.base = base
            self.pauseScale = pauseScale
            self.reachableWPM = reachableWPM
        }
    }

    /// The clock for `wpm`, from token `start` (where reading starts or resumes) to the end.
    ///
    /// Word-only speed: base 60 / wpm, full pauses. Real speed: solved so that reading from `start`
    /// to the end, flash by flash as the reader shows them (`flashes`, in order; single tokens if
    /// not given), with the ease-in from `rampStep` and no flash shorter than `minimumFlash`
    /// seconds (2 display frames), takes exactly words / wpm minutes. The words run faster to
    /// make room for the pauses, up to `maxWordSpeedup`; past that the pauses shrink; if even
    /// that cannot reach the speed (flashes stuck at the minimum, as with long identifiers split
    /// into pieces on a 60 Hz screen), the fastest clock is returned with `reachableWPM` set.
    public func clock(forWPM wpm: Double? = nil, from start: Int = 0, flashes: [Range<Int>]? = nil,
                      rampStep: Int = 0, minimumFlash: Double = 0) -> Clock {
        let start = min(max(0, start), slots.count)
        let flashes = flashes ?? (start..<slots.count).map { $0..<($0 + 1) }
        let w = max(1, wpm ?? options.wpm)
        let nominal = 60.0 / w
        let words = wordStarts[start...].reduce(0, +)
        guard options.realSpeed, words > 0 else { return Clock(base: nominal, pauseScale: 1) }
        let target = Double(words) * 60.0 / w

        func total(_ clock: Clock) -> Double {
            var t = 0.0
            for (i, flash) in flashes.enumerated() {
                var d = seconds(for: flash, clock: clock)
                let step = rampStep + i
                if options.rampUp, step < Self.rampWords {
                    d *= 1 + 0.8 * Double(Self.rampWords - step) / Double(Self.rampWords)
                }
                t += max(d, minimumFlash)
            }
            return t
        }

        let lowest = nominal / Self.maxWordSpeedup
        if total(Clock(base: lowest, pauseScale: 1)) >= target {
            let floor = total(Clock(base: lowest, pauseScale: 0))
            if floor >= target {
                return Clock(base: lowest, pauseScale: 0, reachableWPM: Double(words) * 60 / floor)
            }
            var lo = 0.0, hi = 1.0
            for _ in 0..<50 {
                let mid = (lo + hi) / 2
                if total(Clock(base: lowest, pauseScale: mid)) < target { lo = mid } else { hi = mid }
            }
            return Clock(base: lowest, pauseScale: (lo + hi) / 2)
        }
        var lo = lowest, hi = nominal
        while total(Clock(base: hi, pauseScale: 1)) < target { hi *= 2 }
        for _ in 0..<50 {
            let mid = (lo + hi) / 2
            if total(Clock(base: mid, pauseScale: 1)) < target { lo = mid } else { hi = mid }
        }
        return Clock(base: (lo + hi) / 2, pauseScale: 1)
    }

    /// Seconds to show the tokens `range`; `rampStep` counts chunks since the last start or resume.
    public func seconds(for range: Range<Int>, clock: Clock, rampStep: Int? = nil) -> TimeInterval {
        var t = 0.0
        for k in range where k < slots.count {
            t += clock.base * slots[k] + clock.pauseScale * max(clock.base * pauseSlots[k], pauseFloors[k])
        }
        if options.rampUp, let step = rampStep, step < Self.rampWords {
            t *= 1 + 0.8 * Double(Self.rampWords - step) / Double(Self.rampWords)
        }
        return t
    }

    /// Seconds to read from token `index` to the end without pausing.
    public func remaining(from index: Int, clock: Clock) -> TimeInterval {
        guard index < slots.count else { return 0 }
        return seconds(for: max(0, index)..<slots.count, clock: clock)
    }

    /// The time the ease-in adds over `chunks` (the next flashes after a start or resume), from
    /// ease-in step `step` on.
    public func rampExtra(_ clock: Clock, _ chunks: [Range<Int>], step: Int = 0) -> Double {
        guard options.rampUp else { return 0 }
        var t = 0.0
        for (i, chunk) in chunks.prefix(max(0, Self.rampWords - step)).enumerated() {
            let s = step + i
            t += seconds(for: chunk, clock: clock) * 0.8 * Double(Self.rampWords - s) / Double(Self.rampWords)
        }
        return t
    }

    // MARK: - Pauses

    static func pauseSlot(_ pause: Pause) -> Double {
        switch pause {
        case .none: return 0
        case .clause: return 0.5
        case .line: return 0.7
        case .sentence: return 1.2
        case .paragraph: return 2.0
        }
    }

    /// 200 to 1000 ms between sentences helped RSVP readers in the studies reviewed in PACING.md.
    static func pauseFloor(_ pause: Pause) -> Double {
        switch pause {
        case .sentence: return 0.2
        case .paragraph: return 0.4
        default: return 0
        }
    }

    // MARK: - Classic word slots (adaptive off)

    static func classicSlot(_ token: Token, lengthPause: Bool) -> Double {
        var w = 1.0
        guard lengthPause else { return w }
        let letters = token.text.reduce(0) { $0 + ($1.isLetter || $1.isNumber ? 1 : 0) }
        if letters > 6 { w += min(0.6, Double(letters - 6) * 0.08) }
        if letters >= 3, token.text.contains(where: { $0.isNumber }) { w += 0.25 }
        if token.isLink { w += 0.4 }
        return w
    }

    // MARK: - Adaptive word slots

    /// Words that open a clause of reasoning; given extra time in Castelhano & Muter (2001).
    static let connectives: Set<String> = ["if", "because", "although", "though", "unless", "therefore",
                                          "however", "whereas", "since"]

    static func adaptiveSlots(document: Document, frequency: FrequencyTable?) -> [Double] {
        let tokens = document.tokens
        let text = document.text as NSString
        var raw = [Double](repeating: 1, count: tokens.count)
        var seen = Set<String>()
        var k = 0
        while k < tokens.count {
            // All pieces of one source word share its range.
            var end = k + 1
            while end < tokens.count, tokens[end].isContinuation { end += 1 }
            // A dash compound ("1990–2000", "cat—dog") is several tokens sharing one source range:
            // each part is timed by its own text. Pieces of a split long word use the whole word.
            let source = text.substring(with: tokens[k].range)
            let sharesRange = (k > 0 && tokens[k - 1].range == tokens[k].range)
                || (end < tokens.count && tokens[end].range == tokens[k].range)
            let word = sharesRange
                ? tokens[k..<end].map { $0.continues && $0.text.hasSuffix("-") && !source.contains("-")
                    ? String($0.text.dropLast()) : $0.text }.joined()
                : source
            let pieces = end - k
            let shared = wordExtra(word, isLink: tokens[k].isLink, frequency: frequency, seen: &seen)
            for p in k..<end {
                let letters = tokens[p].text.reduce(0) { $0 + ($1.isLetter ? 1 : 0) }
                // 2 to 11 ms a letter in eye tracking, depending on skipping: 4% of a slot past 6.
                let length = min(0.40, 0.04 * Double(max(0, letters - 6)))
                raw[p] = 1 + shared / Double(pieces) + length
            }
            k = end
        }
        // Spillover: a hard word slows the next one a little too (Smith & Levy 2013).
        var spilled = raw
        for i in 1..<max(1, raw.count) where raw[i - 1] > 1 && !tokens[i].isContinuation {
            spilled[i] += 0.3 * (raw[i - 1] - 1)
        }
        // Normalise the word slots to average 1, so the words run at the chosen speed.
        let mean = spilled.reduce(0, +) / Double(max(1, spilled.count))
        return mean > 0 ? spilled.map { $0 / mean } : spilled
    }

    /// Extra slots for one source word: frequency, digits, link, connective. Shared by its pieces.
    static func wordExtra(_ word: String, isLink: Bool, frequency: FrequencyTable?, seen: inout Set<String>) -> Double {
        if isLink { return 0.4 }
        if word.contains(where: { $0.isNumber }) { return numberExtra(word) }
        let key = word.lowercased().filter { $0.isLetter || $0 == "'" || $0 == "-" }
        var extra = 0.0
        if let frequency, let z = frequency.zipf(of: word) {
            // About 20 ms per tenfold drop in frequency on a 250 ms gaze (Schilling 1998, as tabled in
            // Reichle et al. 2009): 8% of a slot per Zipf unit around Zipf 5, clamped to -0.2..+0.28.
            var f = 0.08 * min(3.5, max(-2.5, 5.0 - z))
            // Seen earlier in this text: a rare word is easier the second time (Raney & Rayner 1995).
            if f > 0, seen.contains(key) { f /= 2 }
            extra += f
        }
        if !key.isEmpty { seen.insert(key) }
        if connectives.contains(key) { extra += 0.3 }
        return extra
    }

    /// More significant digits take longer; round numbers less (de Chambrier et al. 2023, 2025).
    /// "2024" counts as a year (2 digits' worth), "1,000" as one digit, "$12,345,678" as eight.
    static func numberExtra(_ word: String) -> Double {
        let digits = word.filter { $0.isNumber }
        var significant = digits.count
        let core = word.trimmingCharacters(in: CharacterSet(charactersIn: "()[]\"'“”‘’.,;:!?—–-"))
        if core.count == 4, core.allSatisfy({ $0.isNumber }), let year = Int(core), (1000...2099).contains(year) {
            significant = 2
        } else {
            significant -= digits.reversed().prefix(while: { $0 == "0" }).count
        }
        return min(1.2, 0.15 * Double(max(1, significant)))
    }
}
