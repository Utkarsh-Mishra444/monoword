import AppKit
import MonowordCore

/// `Monoword --render <text file> <out dir> [wpm]`: plays a text in the real reader headless (no
/// window on screen, preferences held in memory only) and writes every flash as the app draws it,
/// NNNN.png, plus frames.txt with how long the running app holds each one on a 60 Hz display.
/// For demo animations (the files feed ffmpeg's concat demuxer). The app never comes here
/// without the flag.
///
/// The sequence is what he sees when a text opens: the first word still for the settle beat
/// (0000), then every flash in order with the ease-in, the real-speed clock and the frame
/// quantizer of `ReaderController`, then the reader paused on the last flash, the sentence
/// around it shown, held 2 s.
enum RenderMode {
    static let usage = "usage: Monoword --render <text file> <out dir> [wpm, default 500]"
    static let finalHold: TimeInterval = 2.0

    static func run(arguments: [String]) {
        guard arguments.count >= 2, !arguments[0].hasPrefix("-"), !arguments[1].hasPrefix("-") else { fail(usage) }
        let textURL = URL(fileURLWithPath: (arguments[0] as NSString).expandingTildeInPath)
        let out = URL(fileURLWithPath: (arguments[1] as NSString).expandingTildeInPath)
        let wpm = arguments.count > 2 && !arguments[2].hasPrefix("-") ? Int(arguments[2]) : 500
        guard let wpm, Settings.wpmRange.contains(wpm) else {
            fail("wpm must be a whole number from \(Settings.wpmRange.lowerBound) to \(Settings.wpmRange.upperBound)\n\(usage)")
        }
        guard let text = try? String(contentsOf: textURL, encoding: .utf8) else { fail("cannot read \(textURL.path)") }
        do {
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        } catch {
            fail("cannot create \(out.path): \(error.localizedDescription)")
        }

        // A new install's defaults (dark, San Francisco 46 pt, adaptive pacing, auto grouping, real
        // speed, ease-in) at the speed asked; nothing is read from or written to his preferences.
        let settings = Settings(defaults: MemoryDefaults(suiteName: "Monoword.render.\(getpid())")!)
        Settings.shared = settings
        settings.wpm = wpm
        settings.autoStart = false      // the clock is stepped by hand below; the settle beat is frame 0000
        settings.closeWhenDone = false
        guard let url = AppDelegate.frequencyListURL, let list = try? String(contentsOf: url, encoding: .utf8) else {
            fail("word frequency list not found (adaptive pacing needs it)")
        }
        ReaderController.frequency = FrequencyTable(listText: list)

        let reader = ReaderController.shared
        reader.headless = true          // show() returns before the panel is ordered on screen
        reader.manualClock = true
        reader.open(text: text, source: .url)   // monoword://read?file=..., the Claude Code plugin's path
        guard let session = reader.session, let view = reader.panel?.readerView else { fail("the text has no words") }

        var lines = ["# file\tseconds\tframes_60hz\tstate\tshown"]
        var total = 0.0
        var flashTotal = 0.0
        var pixels = ""
        func write(_ n: Int, frames: Int, seconds: Double, state: String) {
            let name = String(format: "%04d.png", n)
            guard let png = snapshot(view, pixels: &pixels) else { fail("could not render \(name)") }
            do { try png.write(to: out.appendingPathComponent(name)) } catch { fail("cannot write \(name): \(error.localizedDescription)") }
            lines.append("\(name)\t\(String(format: "%.6f", seconds))\t\(frames)\t\(state)\t\(view.state.word)")
            total += seconds
        }

        // Opened, not yet moving: the settle beat before autoStart's play().
        let settleFrames = Int((ReaderController.settleBeforeStart * 60).rounded())
        write(0, frames: settleFrames, seconds: Double(settleFrames) / 60, state: "open")

        reader.play()
        var n = 1
        while true {
            let hold = reader.manualHold
            write(n, frames: hold.frames, seconds: hold.seconds, state: "flash")
            flashTotal += hold.seconds
            if session.isAtLastChunk { break }
            reader.manualTick()
            n += 1
        }
        // Paused on the last flash (as with space): the sentence around it shows below the word.
        reader.pause()
        let finalFrames = Int((finalHold * 60).rounded())
        write(n + 1, frames: finalFrames, seconds: Double(finalFrames) / 60, state: "paused")

        do {
            try (lines.joined(separator: "\n") + "\n").write(to: out.appendingPathComponent("frames.txt"),
                                                           atomically: true, encoding: .utf8)
        } catch {
            fail("cannot write frames.txt: \(error.localizedDescription)")
        }
        let words = session.document.wordCount
        print("rendered \(n + 2) frames (\(n) flashes) of \(words) words at \(wpm) wpm, \(pixels) px, into \(out.path)")
        print(String(format: "flashes %.3f s (words / wpm = %.3f s, %.1f wpm real); with the settle beat and the pause %.3f s",
                     flashTotal, Double(words) * 60 / Double(wpm), Double(words) / flashTotal * 60, total))
        print(String(format: "settings: theme %@, font %@ %.0f pt, adaptive %@, words per flash %@, ease-in %@, real speed %@",
                     settings.theme.rawValue, settings.font.rawValue, settings.fontSize, String(settings.adaptivePacing),
                     settings.chunkSize == 0 ? "auto" : String(settings.chunkSize), String(settings.rampUp),
                     String(settings.realSpeed)))
        exit(0)
    }

    /// The reader view as the app draws it (the self-test's snapshot), as PNG data.
    private static func snapshot(_ view: NSView, pixels: inout String) -> Data? {
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        pixels = "\(rep.pixelsWide)x\(rep.pixelsHigh)"
        return rep.representation(using: .png, properties: [:])
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data((message + "\n").utf8))
        exit(2)
    }
}

/// Preferences that live in memory for this run only: reads fall back to the registered defaults,
/// writes never reach disk, so a render cannot touch his settings or leave a domain behind.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]

    override func object(forKey key: String) -> Any? { values[key] ?? super.object(forKey: key) }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values[key] = nil }
    override func set(_ value: Int, forKey key: String) { values[key] = value }
    override func set(_ value: Double, forKey key: String) { values[key] = value }
    override func set(_ value: Float, forKey key: String) { values[key] = value }
    override func set(_ value: Bool, forKey key: String) { values[key] = value }
    override func string(forKey key: String) -> String? { object(forKey: key) as? String }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func integer(forKey key: String) -> Int { (object(forKey: key) as? NSNumber)?.intValue ?? 0 }
    override func double(forKey key: String) -> Double { (object(forKey: key) as? NSNumber)?.doubleValue ?? 0 }
    override func bool(forKey key: String) -> Bool { (object(forKey: key) as? NSNumber)?.boolValue ?? false }
}
