import Foundation
import Testing
@testable import MonowordCore

// The timetable `monoword-schedule` prints for the Claude Code plugin's terminal band.

private let scheduleFrequency: FrequencyTable = {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/word-frequency-en.txt")
    return FrequencyTable(listText: (try? String(contentsOf: url, encoding: .utf8)) ?? "")
}()

/// About 300 words of plain prose, made up here: sentences of 4 to 22 words from a fixed list,
/// commas inside the longer ones, a paragraph break every 6 sentences, a number now and then.
/// A fixed linear congruential generator, so every run reads the same text.
private func generatedProse(words target: Int = 300) -> String {
    let vocabulary = ("the light from a clear sky reaches your eyes after it scatters off the air and "
        + "each colour bends by a different amount so short blue waves spread across the whole dome "
        + "while longer red waves pass straight through which is why sunsets glow orange near the "
        + "horizon photosynthesis atmosphere wavelength molecules particularly observation "
        + "nevertheless approximately consequently the it is to of in on").split(separator: " ").map(String.init)
    var seed: UInt64 = 0x5EED
    func next(_ n: Int) -> Int {
        seed = seed &* 6364136223846793005 &+ 1442695040888963407
        return Int((seed >> 33) % UInt64(n))
    }
    var out = ""
    var count = 0
    var sentence = 0
    while count < target {
        let length = min(4 + next(19), target - count)
        var words: [String] = []
        for k in 0..<length {
            var w = vocabulary[next(vocabulary.count)]
            if next(29) == 0 { w = String(10 + next(990)) }
            if k == 0 { w = w.prefix(1).uppercased() + w.dropFirst() }
            if k > 2, k < length - 2, next(7) == 0 { w += "," }
            words.append(w)
        }
        out += words.joined(separator: " ") + "."
        count += length
        sentence += 1
        out += sentence % 6 == 0 ? "\n\n" : " "
    }
    return out
}

@Test func generatedProseIsAbout300Words() {
    #expect(scheduleFrequency.count == 50_000, "the word frequency list loaded")
    let doc = Document(raw: generatedProse())
    #expect((290...310).contains(doc.wordCount), "\(doc.wordCount) words")
}

@Test func scheduleTotalIsRealSpeed() {
    // Real speed: the whole schedule takes words / wpm minutes, pauses and ease-in included.
    let doc = Document(raw: generatedProse())
    for wpm in [100.0, 300, 500, 800, 1000, 1500] {
        for chunk in [ReadingSession.auto, 1] {
            let options = TimingOptions(wpm: wpm, punctuationPause: 1, lengthPause: true, rampUp: true,
                                        adaptive: true, realSpeed: true)
            let schedule = Schedule(document: doc, timing: options, chunkSize: chunk, frequency: scheduleFrequency)
            let target = Double(doc.wordCount) * 60 / wpm
            let promised = schedule.clock.reachableWPM.map { Double(doc.wordCount) * 60 / min($0, wpm) } ?? target
            let error = abs(schedule.total - promised) / promised
            #expect(error <= 0.01, "\(Int(wpm)) wpm chunk \(chunk): \(schedule.total) s vs \(promised) s")
            #expect(schedule.flashes.allSatisfy { $0.seconds >= schedule.minimumFlash - 1e-12 })
            #expect(schedule.flashes.reduce(0) { $0 + $1.words } == doc.wordCount)
        }
    }
}

@Test func scheduleHoldsAreTheReaderTiming() {
    // Every hold is what the app's reader asks for, flash by flash (ReaderController.play then
    // tick): the same Pacing, the clock solved once from the first flash with the 2-frame minimum
    // at 60 Hz, flash i at ease-in step i. Rebuilt here from those parts, not from Schedule.
    let doc = Document(raw: generatedProse())
    let options = TimingOptions(wpm: 500, punctuationPause: 1, lengthPause: true, rampUp: true,
                                adaptive: true, realSpeed: true)
    let session = ReadingSession(document: doc, chunkSize: ReadingSession.auto)
    let pacing = Pacing(document: doc, options: options, frequency: scheduleFrequency)
    let minimum = Double(FrameQuantizer.minimumFrames) / 60
    let clock = pacing.clock(forWPM: 500, from: 0, flashes: session.chunks(from: 0, count: .max),
                             rampStep: 0, minimumFlash: minimum)
    let exact = Schedule(document: doc, timing: options, chunkSize: ReadingSession.auto, frequency: scheduleFrequency)
    let framed = Schedule(document: doc, timing: options, chunkSize: ReadingSession.auto,
                          frequency: scheduleFrequency, frameRate: 60, quantize: true)
    #expect(exact.clock == clock)
    var quantizer = FrameQuantizer(frameDuration: 1.0 / 60)
    var step = 0
    repeat {
        #expect(step < exact.flashes.count)
        guard step < exact.flashes.count else { break }
        let interval = pacing.seconds(for: session.currentRange, clock: clock, rampStep: step)
        #expect(exact.flashes[step].text == session.currentText)
        #expect(exact.flashes[step].tokens == session.currentRange)
        #expect(exact.flashes[step].seconds == max(interval, minimum))
        #expect(framed.flashes[step].seconds == Double(quantizer.frames(for: interval)) / 60)
        step += 1
    } while session.advance()
    #expect(step == exact.flashes.count)
    // On a 60 Hz display the frames carry their rounding, so the total stays within 2%.
    #expect(abs(framed.total - exact.total) / exact.total <= 0.02)
}

@Test func emptyScheduleHasNoFlashes() {
    let schedule = Schedule(text: "  \n ", timing: TimingOptions(wpm: 500, adaptive: true), frequency: scheduleFrequency)
    #expect(schedule.flashes.isEmpty)
    #expect(schedule.total == 0)
}
