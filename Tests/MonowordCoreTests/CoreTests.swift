import Foundation
import Testing
@testable import MonowordCore

// MARK: - Cleaning

@Test func cleanCollapsesSpacesAndKeepsParagraphs() {
    let out = TextCleaner.clean("  Hello   world.\n\n\nSecond  para.  ")
    #expect(out == "Hello world.\n\nSecond para.")
}

@Test func cleanJoinsTerminalWrappedLines() {
    // Claude Code style: hard-wrapped at ~60 columns with a two-space indent and a ⏺ bullet.
    let raw = """
    ⏺ The reader shows one word at a time at a fixed point so the
      eye never has to move, which is what makes high speeds
      comfortable.
    """
    let out = TextCleaner.clean(raw)
    #expect(out == "The reader shows one word at a time at a fixed point so the eye never has to move, which is what makes high speeds comfortable.")
}

@Test func cleanKeepsDeliberateShortLines() {
    let raw = "This changed everything for me, honestly the best tool I have used all year\nShort line\nAnother one"
    let out = TextCleaner.clean(raw)
    #expect(out.contains("Short line\nAnother one"))
}

@Test func cleanStripsBoxDrawingAndAnsi() {
    let raw = "╭──────────╮\n│ \u{1B}[1mBold\u{1B}[0m text │\n╰──────────╯"
    #expect(TextCleaner.clean(raw) == "Bold text")
}

@Test func cleanMarkdown() {
    let raw = "# Title\n\nSome **bold** and *em* text with a [link](https://example.com/x) and `code`.\n\n- first item\n- second item\n\n```\nlet x = 1\n```"
    let out = TextCleaner.clean(raw)
    #expect(out == "Title\n\nSome bold and em text with a link and code.\n\nfirst item\n\nsecond item\n\nlet x = 1")
}

@Test func cleanKeepsSnakeCaseAndMultiplication() {
    #expect(TextCleaner.clean("use snake_case_names and 2 * 3 * 4") == "use snake_case_names and 2 * 3 * 4")
}

@Test func cleanRejoinsHyphenatedLineBreak() {
    let raw = "This sentence was typeset in a narrow column and the word exam-\nple was hyphenated across lines."
    #expect(TextCleaner.clean(raw).contains("example was"))
}

@Test func cleanRemovesZeroWidthAndSoftHyphen() {
    #expect(TextCleaner.clean("in\u{00AD}ter\u{200B}na\u{FEFF}tional") == "international")
}

// MARK: - Tokenizing

private func texts(_ s: String, _ o: TokenizerOptions = .init()) -> [String] {
    Document(raw: s, options: o).tokens.map(\.text)
}

@Test func tokenizeBasics() {
    let doc = Document(raw: "Hello, world. How are you?")
    #expect(doc.tokens.map(\.text) == ["Hello,", "world.", "How", "are", "you?"])
    #expect(doc.tokens.map(\.pause) == [.clause, .sentence, .none, .none, .paragraph])
    #expect(doc.sentenceStarts == [0, 2])
    #expect(doc.tokens.map(\.sentence) == [0, 0, 1, 1, 1])
}

@Test func tokenRangesPointIntoCleanText() {
    let doc = Document(raw: "naïve café 🎉 test")
    let ns = doc.text as NSString
    #expect(doc.tokens.map { ns.substring(with: $0.range) } == ["naïve", "café", "🎉", "test"])
}

@Test func abbreviationsDoNotEndSentences() {
    let doc = Document(raw: "Dr. Smith met e.g. friends in the U.S. Then he left.")
    let pauses = Dictionary(uniqueKeysWithValues: doc.tokens.map { ($0.text, $0.pause) })
    #expect(pauses["Dr."] == Pause.none)
    #expect(pauses["e.g."] == Pause.none)
    #expect(pauses["U.S."] == .sentence)  // a capital follows
}

@Test func dashesSplitWords() {
    #expect(texts("fast—really fast") == ["fast—", "really", "fast"])
    #expect(texts("wait...what") == ["wait...", "what"])
    #expect(texts("well-known") == ["well-known"])
}

@Test func standalonePunctuationMergesIntoPreviousWord() {
    let doc = Document(raw: "one — two")
    #expect(doc.tokens.map(\.text) == ["one —", "two"])
    #expect(doc.tokens[0].pause == .clause)
}

@Test func linksAreShortened() {
    #expect(texts("see https://www.example.com/some/very/long/path?q=1.") == ["see", "example.com."])
    #expect(texts("(https://t.co/AbCdEf)") == ["t.co"])
    #expect(Document(raw: "https://x.com/a").tokens[0].isLink)
}

@Test func linksKeptWhenNotShortening() {
    let o = TokenizerOptions(shortenLinks: false, maxPieceLength: 40)
    #expect(texts("go to https://example.com/a now", o) == ["go", "to", "https://example.com/a", "now"])
}

@Test func longWordsAreSplit() {
    let pieces = texts("internationalization")
    #expect(pieces.count == 2)
    #expect(pieces.joined().replacingOccurrences(of: "-", with: "") == "internationalization")
    #expect(pieces.allSatisfy { $0.count <= 13 })
    let doc = Document(raw: "internationalization")
    #expect(doc.tokens[0].continues && !doc.tokens[0].isContinuation)
    #expect(doc.tokens[1].isContinuation && !doc.tokens[1].continues)
    #expect(doc.wordCount == 1)
}

@Test func camelCaseIdentifiersSplitAtHumps() {
    let pieces = texts("AXUIElementCopyAttributeValue")
    #expect(pieces.allSatisfy { $0.count <= 13 })
    #expect(pieces.joined().replacingOccurrences(of: "-", with: "") == "AXUIElementCopyAttributeValue")
}

@Test func pathsSplitAtSlashes() {
    let pieces = texts("Sources/MonowordCore/Tokenizer.swift")
    #expect(pieces.allSatisfy { $0.count <= 13 })
    #expect(pieces.first == "Sources/")
    #expect(pieces.joined().replacingOccurrences(of: "-", with: "") == "Sources/MonowordCore/Tokenizer.swift")
}

@Test func lineBreaksAreSoftSentenceBoundaries() {
    let doc = Document(raw: "gm\nshipping today\nlets go")
    #expect(doc.tokens.map(\.pause) == [.line, .none, .line, .none, .paragraph])
    #expect(doc.sentenceStarts == [0, 1, 3])
}

@Test func emptyInput() {
    #expect(Document(raw: "   \n\n  ").isEmpty)
    #expect(Document(raw: "— • |").isEmpty)
}

// MARK: - Timing

private func wordOnly(_ wpm: Double, pauses: Double = 1, length: Bool = true) -> TimingOptions {
    TimingOptions(wpm: wpm, punctuationPause: pauses, lengthPause: length, realSpeed: false)
}

@Test func wordOnlyTiming() {
    let doc = Document(raw: "go, now. extraordinarily")
    let plain = Pacing(document: doc, options: wordOnly(600, pauses: 0, length: false))
    #expect(abs(plain.seconds(for: 1..<2, clock: plain.clock()) - 0.1) < 1e-9)
    let p = Pacing(document: doc, options: wordOnly(600))
    let c = p.clock()
    let comma = p.seconds(for: 0..<1, clock: c), period = p.seconds(for: 1..<2, clock: c)
    #expect(comma > 0.1 && period > comma)
    #expect(p.seconds(for: 1..<2, clock: c, rampStep: 0) > period)
    #expect(p.seconds(for: 1..<2, clock: c, rampStep: Pacing.rampWords) == period)
}

@Test func remainingTimeShrinks() {
    let doc = Document(raw: String(repeating: "word ", count: 100))
    let p = Pacing(document: doc, options: wordOnly(300, pauses: 0, length: false))
    #expect(abs(p.remaining(from: 0, clock: p.clock()) - 20) < 0.5)
    #expect(p.remaining(from: 50, clock: p.clock()) < p.remaining(from: 0, clock: p.clock()))
    #expect(abs(p.remaining(from: 0, clock: p.clock(forWPM: 600)) - 10) < 0.5)
}

@Test func sentencePausesHaveAFloor() {
    let doc = Document(raw: "One. Two three")
    let p = Pacing(document: doc, options: wordOnly(1200))
    // 1.2 slots at 1200 wpm is 60 ms; the floor keeps the sentence pause at 200 ms.
    #expect(p.seconds(for: 0..<1, clock: p.clock()) >= 0.05 + 0.2 - 1e-9)
    let off = Pacing(document: doc, options: wordOnly(1200, pauses: 0))
    #expect(off.seconds(for: 0..<1, clock: off.clock()) < 0.1)
}

// MARK: - Real speed (the guard: the number shown is the rate he actually reads at)

private let prose = String(repeating: """
    The committee met on Tuesday to review the budget, which had grown by almost a third since the \
    previous year. Several members argued that the increase was justified; others wanted cuts. In the \
    end, they agreed to postpone the vote until the auditors had finished their report.

    """, count: 6)
private let listHeavy = String(repeating: """
    Here is the plan:
    - build the reader first
    - test it on real text, tweets and terminal output
    - fix what breaks.

    Then ship it. Done.

    """, count: 8)
private let tweets = String(repeating: "gm\nshipping today 🚀\nlets go. who is in?\n\n", count: 15)
private let code = String(repeating: "Call `AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute)` first, then `restore(saved)`. ", count: 20)

/// Reads `text` the way the reader does: from `startFraction` of the way in to the end, flash
/// by flash, ease-in included, each flash held a whole number of frames at `hz` (nil: exact
/// times). Returns the real words per minute and the clock the reader solved.
private func readThrough(_ text: String, _ options: TimingOptions, chunk: Int, hz: Double? = nil,
                         startFraction: Double = 0) -> (wpm: Double, clock: Pacing.Clock) {
    let doc = Document(raw: text)
    let pacing = Pacing(document: doc, options: options, frequency: frequency)
    let session = ReadingSession(document: doc, chunkSize: chunk)
    session.seek(to: Int(Double(doc.tokens.count) * startFraction))
    let start = session.index
    let minimum = hz.map { Double(FrameQuantizer.minimumFrames) / $0 } ?? 0
    let clock = pacing.clock(from: start, flashes: session.chunks(from: start, count: .max), minimumFlash: minimum)
    var quantizer = hz.map { FrameQuantizer(frameDuration: 1 / $0) }
    var seconds = 0.0, step = 0, words = 0
    repeat {
        let d = pacing.seconds(for: session.currentRange, clock: clock, rampStep: step)
        if var q = quantizer {
            seconds += Double(q.frames(for: d)) * q.frameDuration
            quantizer = q
        } else {
            seconds += d
        }
        words += session.currentRange.filter { !doc.tokens[$0].isContinuation }.count
        step += 1
    } while session.advance()
    return (Double(words) / seconds * 60, clock)
}

private func realWPM(_ text: String, _ options: TimingOptions, chunk: Int) -> Double {
    readThrough(text, options, chunk: chunk).wpm
}

@Test func realSpeedMatchesTheSetting() {
    // The guard (2026-10-19): the speed shown is the speed read. Every text kind, every speed the
    // slider offers, every pause setting, pacing mode and grouping mode, from the start and from
    // half way, with exact times and on 60 Hz and 120 Hz displays. Where a text cannot reach the
    // setting on a display, the reader shows `reachableWPM` instead, and that is what is checked.
    var worst = 0.0
    var worstCase = ""
    var unreachable = 0
    for (name, text) in [("prose", prose), ("lists", listHeavy), ("tweets", tweets), ("code", code)] {
        #expect(Document(raw: text).wordCount >= 100, "\(name) is long enough to measure")
        for wpm in [100.0, 400, 1000, 1500] {
            for pauses in [0.0, 0.5, 1, 2] {
                for adaptive in [true, false] {
                    for chunk in [ReadingSession.auto, 1, 2, 3] {
                        for start in [0.0, 0.5] {
                            for hz in [nil, 60.0, 120.0] as [Double?] {
                                let o = TimingOptions(wpm: wpm, punctuationPause: pauses, adaptive: adaptive)
                                let (real, clock) = readThrough(text, o, chunk: chunk, hz: hz, startFraction: start)
                                let promised = clock.reachableWPM.map { min($0, wpm) } ?? wpm
                                if clock.reachableWPM != nil { unreachable += 1 }
                                let error = abs(real - promised) / promised
                                let allowed = hz == nil ? 0.01 : 0.02
                                if error / allowed > worst {
                                    worst = error / allowed
                                    worstCase = "\(name) \(Int(wpm)) pauses \(pauses) adaptive \(adaptive) chunk \(chunk) start \(start) hz \(hz ?? 0): \(Int(real)) vs \(Int(promised))"
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    // Before real speed, "500" read at 377 on a list-heavy text: a 25% error.
    #expect(worst <= 1, "worst \(worstCase)")
    print("info real-speed grid: worst \(String(format: "%.2f", worst)) of tolerance (\(worstCase)); \(unreachable) cells unreachable on their display")
}

@Test func unreachableSpeedIsReported() {
    // Long identifiers split into pieces cannot flash faster than 2 frames each on 60 Hz.
    let o = TimingOptions(wpm: 1500, punctuationPause: 0, adaptive: false)
    let (real, clock) = readThrough(code, o, chunk: 1, hz: 60)
    let reachable = clock.reachableWPM
    #expect(reachable != nil && reachable! < 1500)
    #expect(abs(real - (reachable ?? 0)) / (reachable ?? 1) < 0.02)
    #expect(readThrough(prose, TimingOptions(wpm: 1000), chunk: 1, hz: 60).clock.reachableWPM == nil)
}

@Test func wordOnlySpeedStillAvailable() {
    let o = TimingOptions(wpm: 500, punctuationPause: 1, adaptive: true, realSpeed: false)
    #expect(realWPM(listHeavy, o, chunk: 1) < 450)   // pauses on top, as before
}

// MARK: - Adaptive pacing

private let frequency: FrequencyTable = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/word-frequency-en.txt")
    return FrequencyTable(listText: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
}()

@Test func zipfValues() throws {
    #expect(frequency.count == 50_000)
    let the = try #require(frequency.zipf(of: "The"))
    let rare = try #require(frequency.zipf(of: "photosynthesis,"))
    #expect(abs(the - 7.5) < 0.1)
    #expect(abs(rare - 2.6) < 0.1)
    #expect(frequency.zipf(of: "don't") == frequency.zipf(of: "don"))
    #expect(frequency.zipf(of: "qwzxv") == FrequencyTable.unknownZipf)
    #expect(frequency.zipf(of: "🎉") == nil)
}

private func adaptive(_ text: String) -> (Document, Pacing) {
    let doc = Document(raw: text)
    return (doc, Pacing(document: doc, options: TimingOptions(wpm: 400, adaptive: true), frequency: frequency))
}

@Test func adaptiveAveragesToTheChosenSpeed() {
    let (_, p) = adaptive("The mitochondria convert nutrients into adenosine triphosphate, which cells spend as energy, and the rest is heat.")
    let mean = p.slots.reduce(0, +) / Double(p.slots.count)
    #expect(abs(mean - 1) < 1e-9)
    #expect(p.slots.min()! > 0.7 && p.slots.max()! < 1.9)
}

@Test func adaptiveGivesRareWordsMoreTime() {
    let (doc, p) = adaptive("the cat saw the chlorophyll in the garden")
    func slot(_ w: String) -> Double { p.slots[doc.tokens.firstIndex(where: { $0.text == w })!] }
    #expect(slot("chlorophyll") > slot("cat"))
    #expect(slot("cat") > slot("the"))
}

@Test func adaptiveNumbers() {
    #expect(Pacing.numberExtra("2024") < Pacing.numberExtra("2,437"))
    #expect(Pacing.numberExtra("1,000") < Pacing.numberExtra("1,437"))
    #expect(Pacing.numberExtra("$12,345,678") == 1.2)
    #expect(Pacing.numberExtra("(1999),") == Pacing.numberExtra("2024"))
}

@Test func adaptiveRepeatedRareWordIsFaster() {
    let (doc, p) = adaptive("zygote forms early and the zygote divides")
    let first = doc.tokens.firstIndex(where: { $0.text == "zygote" })!
    let second = doc.tokens.lastIndex(where: { $0.text == "zygote" })!
    #expect(p.slots[second] < p.slots[first])
}

// MARK: - Session

@Test func sessionAdvancesToEnd() {
    let s = ReadingSession(document: Document(raw: "one two three"))
    var seen = [s.currentText]
    while s.advance() { seen.append(s.currentText) }
    #expect(seen == ["one", "two", "three"])
    #expect(s.isAtLastChunk)
    #expect(s.progress == 2.0 / 3.0)   // read before the words on screen
}

@Test func sessionChunks() {
    let s = ReadingSession(document: Document(raw: "the quick brown fox, jumps over the lazy dog."), chunkSize: 3)
    var seen = [s.currentText]
    while s.advance() { seen.append(s.currentText) }
    #expect(seen == ["the quick brown", "fox,", "jumps over the", "lazy dog."])
}

@Test func sessionChunksNeverMergeSplitPieces() {
    let s = ReadingSession(document: Document(raw: "an internationalization test"), chunkSize: 3)
    var seen = [s.currentText]
    while s.advance() { seen.append(s.currentText) }
    #expect(seen.count == 4)
    #expect(seen.first == "an")
    #expect(seen.last == "test")
}

@Test func sessionSentenceNavigation() {
    let s = ReadingSession(document: Document(raw: "One two three. Four five six. Seven eight."))
    s.seek(to: 4)            // "five"
    s.rewindSentence()
    #expect(s.currentText == "Four")
    s.rewindSentence()       // at the start already: previous sentence
    #expect(s.currentText == "One")
    s.forwardSentence()
    #expect(s.currentText == "Four")
    s.forwardSentence()
    #expect(s.currentText == "Seven")
    s.forwardSentence()      // no next sentence: stays
    #expect(s.currentText == "Seven")
    s.step(-1)
    #expect(s.currentText == "six.")
}

// MARK: - Realistic copies

@Test func claudeCodeTranscript() {
    let raw = """
    ⏺ I'll start by checking the toolchain, then build the reader in a new folder so nothing
      else is touched.

    ⏺ Bash(swift --version)
      ⎿  Apple Swift version 6.2.3

    ⏺ Here is the plan:
      - A menu bar app with a global shortcut that reads whatever is selected in any app on the
        Mac, including the terminal.
      - A floating reader.
    """
    let out = TextCleaner.clean(raw)
    let blocks = out.components(separatedBy: "\n\n")
    #expect(blocks.contains("I'll start by checking the toolchain, then build the reader in a new folder so nothing else is touched."))
    #expect(blocks.contains("A menu bar app with a global shortcut that reads whatever is selected in any app on the Mac, including the terminal."))
    #expect(blocks.contains("A floating reader."))
    #expect(!out.contains("⏺") && !out.contains("⎿"))
}

@Test func tweetWithLinesAndLink() {
    let raw = "shipped the thing tonight 🚀\n\nthree lessons:\n1. start small\n2. ship daily\n3. sleep\n\nhttps://t.co/AbC123xyz"
    let doc = Document(raw: raw)
    #expect(doc.tokens.map(\.text) == ["shipped", "the", "thing", "tonight", "🚀", "three", "lessons:", "start", "small",
                                       "ship", "daily", "sleep", "t.co"])
    #expect(doc.tokens[4].pause == .paragraph)   // after the emoji
    #expect(doc.tokens[8].pause == .paragraph)   // list items are blocks
}

@Test func codeIsReadableNotMangled() {
    let doc = Document(raw: "Call `AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute)` first.")
    #expect(doc.tokens.allSatisfy { $0.text.count <= 14 })
    #expect(doc.tokens.last?.text.hasSuffix("first.") == true)
}

// MARK: - Review findings (2026-10-19)

@Test func codeSurvivesMarkdownStripping() {
    #expect(TextCleaner.clean("call `__init__` in __init__.py") == "call __init__ in __init__.py")
    #expect(TextCleaner.clean("if __name__ == '__main__':") == "if __name__ == '__main__':")
    #expect(TextCleaner.clean("handlers[type](event)") == "handlers[type](event)")
    #expect(TextCleaner.clean("see [the docs](https://x.com/d) and __bold words__") == "see the docs and bold words")
    #expect(TextCleaner.clean("x = a | b") == "x = a | b")
}

@Test func sentenceEndsAroundAbbreviations() {
    func pause(_ text: String, _ word: String) -> Pause? {
        Document(raw: text).tokens.first(where: { $0.text == word })?.pause
    }
    #expect(pause("he said no. Then left", "no.") == .sentence)
    #expect(pause("see no. 5 here", "no.") == Pause.none)
    #expect(pause("by J. K. Rowling today", "J.") == Pause.none)
    #expect(pause("George W. Bush said", "W.") == Pause.none)
    #expect(pause("I waited… and waited", "waited…") == .clause)
    #expect(pause("I waited… Then left", "waited…") == .sentence)
    #expect(pause("so... and then", "so...") == .clause)
}

@Test func schemelessAndTruncatedLinks() {
    #expect(texts("check github.com/anthropics/claude-co… now") == ["check", "github.com", "now"])
    #expect(texts("with https:// and") == ["with", "https://", "and"])
    let o = TokenizerOptions(shortenLinks: false)
    let pieces = Document(raw: "https://example.com/a/very/long/path/that/goes/on/and/on/forever", options: o).tokens
    #expect(pieces.count > 1 && pieces.allSatisfy { $0.isLink && $0.text.count <= 14 })
}

@Test func splitUsesFullWidthAtSlashes() {
    #expect(texts("Read(Sources/MonowordCore/Tokenizer.swift)").first == "Read(Sources/")
}

@Test func lineEndHyphenVariants() {
    let a = "This sentence was typeset in a narrow column and the word exam\u{00AD}\nple was hyphenated across lines."
    #expect(TextCleaner.clean(a).contains("example was"))
    let b = "This sentence was typeset in a narrow column and the word exam\u{2010}\nple was hyphenated across lines."
    #expect(TextCleaner.clean(b).contains("example was"))
}

@Test func xUiLinesAndImagePlaceholderDropped() {
    #expect(TextCleaner.clean("great thread\nShow more") == "great thread")
    #expect(texts("photo \u{FFFC} here") == ["photo", "here"])
}

// MARK: - Right ⌘ double tap

/// Feeds one event and returns whether it completed a double tap.
private func feed(_ d: inout DoubleTapDetector, _ down: Bool, _ t: Double, others: Bool = false) -> Bool {
    d.key(down: down, othersHeld: others, at: t)
}

@Test func doubleTapFiresOnQuickPair() {
    var d = DoubleTapDetector()
    let results = [feed(&d, true, 0.00), feed(&d, false, 0.08), feed(&d, true, 0.25), feed(&d, false, 0.32),
                   // a third tap right after does not fire again on its own
                   feed(&d, true, 0.45), feed(&d, false, 0.50)]
    #expect(results == [false, false, false, true, false, false])
}

@Test func doubleTapIgnoresSlowHeldOrCombined() {
    var slow = DoubleTapDetector()
    _ = feed(&slow, true, 0); _ = feed(&slow, false, 0.1); _ = feed(&slow, true, 0.6)
    let slowFired = feed(&slow, false, 0.7)                  // gap too long
    #expect(!slowFired)

    var held = DoubleTapDetector()
    _ = feed(&held, true, 0); _ = feed(&held, false, 0.1); _ = feed(&held, true, 0.2)
    let heldFired = feed(&held, false, 0.9)                  // second press held
    #expect(!heldFired)

    var shortcut = DoubleTapDetector()
    _ = feed(&shortcut, true, 0); _ = feed(&shortcut, false, 0.1); _ = feed(&shortcut, true, 0.2)
    shortcut.interrupted()                                    // ⌘C
    let shortcutFired = feed(&shortcut, false, 0.25)
    #expect(!shortcutFired)

    var between = DoubleTapDetector()
    _ = feed(&between, true, 0); _ = feed(&between, false, 0.1)
    between.interrupted()                                     // a letter typed between taps
    _ = feed(&between, true, 0.2)
    let betweenFired = feed(&between, false, 0.25)
    #expect(!betweenFired)

    var shifted = DoubleTapDetector()
    _ = feed(&shifted, true, 0, others: true); _ = feed(&shifted, false, 0.1); _ = feed(&shifted, true, 0.2)
    let shiftedFired = feed(&shifted, false, 0.25)           // first tap had ⇧ held
    #expect(!shiftedFired)
}

// MARK: - Second review (2026-10-19)

private func seconds(_ body: () -> Void) -> Double {
    let t0 = Date()
    body()
    return Date().timeIntervalSince(t0)
}

@Test func markdownStaysLinearOnPathologicalLines() {
    let prose = String(repeating: "plain words in a long paragraph ", count: 700)      // ~22k chars
    #expect(seconds { _ = TextCleaner.clean("__dirname " + prose) } < 1.0)
    #expect(seconds { _ = TextCleaner.clean(String(repeating: "**a ", count: 5_000)) } < 1.0)
    #expect(seconds { _ = TextCleaner.clean(String(repeating: "`x` ", count: 2_400)) } < 1.0)
    #expect(seconds { _ = TextCleaner.clean(String(repeating: "[a](http://x ", count: 15_000)) } < 2.0)
    // Just under the 10,000-character line limit, so the rules really run (before bounding the
    // spans, an unclosed "__" here took about 2.4 s).
    let near = String(repeating: "plain words in a long paragraph ", count: 300)        // 9,600 chars
    #expect(seconds { _ = TextCleaner.clean("__dirname " + near) } < 0.5)
    #expect(seconds { _ = TextCleaner.clean(String(repeating: "**a ", count: 2_400)) } < 0.5)
    #expect(seconds { _ = TextCleaner.clean(String(repeating: "~~a ", count: 2_400)) } < 0.5)
    #expect(seconds { _ = TextCleaner.clean(String(repeating: "`x` ", count: 2_400)) } < 0.5)
    #expect(seconds { _ = TextCleaner.clean(String(repeating: "[a](http://x ", count: 750)) } < 0.5)
    // Many code spans still come back in order.
    #expect(TextCleaner.clean("`a` and `b` then `c`") == "a and b then c")
}

@Test func privateUseCharactersCannotForgeSpans() {
    #expect(TextCleaner.clean("x \u{E000}0\u{E001} y `code`") == "x 0 y code")
}

@Test func initialsNeedANameAround() {
    func pause(_ text: String, _ word: String) -> Pause? {
        Document(raw: text).tokens.first(where: { $0.text == word })?.pause
    }
    #expect(pause("I got an A. Then left", "A.") == .sentence)
    #expect(pause("take vitamin C. It helps", "C.") == .sentence)
    #expect(pause("by J. K. Rowling today", "K.") == Pause.none)
    #expect(pause("J. K. Rowling wrote", "J.") == Pause.none)
}

@Test func filePathsAreNotLinks() {
    #expect(texts("use Node.js/Deno here") == ["use", "Node.js/Deno", "here"])
    #expect(texts("edit README.md/CHANGELOG.md") == ["edit", "README.md/", "CHANGELOG.md"])
    #expect(texts("see bun.sh/docs and x.com/a/status/1") == ["see", "bun.sh", "and", "x.com"])
}

@Test func dashCompoundPartsAreTimedSeparately() {
    let (doc, p) = adaptive("from 1990–2000 the cat—dog")
    let a = doc.tokens.firstIndex(where: { $0.text == "1990–" })!
    let b = doc.tokens.firstIndex(where: { $0.text == "2000" })!
    #expect(abs(Pacing.numberExtra("1990–") - Pacing.numberExtra("1990")) < 1e-9)
    #expect(p.slots[a] > 0 && p.slots[b] > 0)
    let (doc2, p2) = adaptive("cat—photosynthesizing")
    #expect(p2.slots[doc2.tokens.firstIndex(where: { $0.text == "cat—" })!] < p2.slots[1])
}

// MARK: - Auto grouping

@Test func autoPairsOnlyTinyFunctionWords() {
    let s = ReadingSession(document: Document(raw: "It is one of the best tools in a house, and the quick brown fox jumped over it."),
                           chunkSize: ReadingSession.auto)
    var seen = [s.currentText]
    while s.advance() { seen.append(s.currentText) }
    #expect(seen == ["It is", "one", "of the", "best", "tools", "in a", "house,", "and the", "quick", "brown",
                     "fox", "jumped", "over", "it."])
    // A tiny word next to a word that carries meaning stays alone: "the fix", "a house", "one of".
    let t = ReadingSession(document: Document(raw: "the fix is a house"), chunkSize: ReadingSession.auto)
    var seen2 = [t.currentText]
    while t.advance() { seen2.append(t.currentText) }
    #expect(seen2 == ["the", "fix", "is a", "house"])
    #expect(seen.allSatisfy { $0.split(separator: " ").count <= 2 })
}

@Test func autoKeepsLongWordsAlone() {
    let s = ReadingSession(document: Document(raw: "Comprehension depends heavily on vocabulary"), chunkSize: ReadingSession.auto)
    var seen = [s.currentText]
    while s.advance() { seen.append(s.currentText) }
    #expect(seen == ["Comprehension", "depends", "heavily", "on", "vocabulary"])
}

// MARK: - Glue across lines (2026-10-19: "sentence ↑ / ↓:" flashed as one)

@Test func punctuationNeverJoinsAcrossLines() {
    let doc = Document(raw: "In the reader:\n- ←: reread the sentence\n- ↑ / ↓: speed\n- esc: close")
    #expect(!doc.tokens.contains { $0.text.contains("sentence") && $0.text.count > "sentence".count })
    #expect(doc.tokens.contains { $0.text == "←:" })
    #expect(doc.tokens.map(\.text).contains("↓:"))
    let s = ReadingSession(document: doc, chunkSize: ReadingSession.auto)
    var seen = [s.currentText]
    while s.advance() { seen.append(s.currentText) }
    #expect(seen.allSatisfy { $0.split(separator: " ").count <= 2 }, "\(seen)")
}

@Test func numbersNeverPair() {
    let s = ReadingSession(document: Document(raw: "it was 482 wpm at 5.6 a second"), chunkSize: ReadingSession.auto)
    var seen = [s.currentText]
    while s.advance() { seen.append(s.currentText) }
    #expect(!seen.contains { $0.contains("482 ") || $0.contains(" 482") || $0.contains("5.6 ") })
}
