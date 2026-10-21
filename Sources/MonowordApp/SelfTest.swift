import AppKit
import Carbon.HIToolbox
import MonowordCore
import SwiftUI

/// `Monoword --selftest <dir>`: drives the real reader headless (no window on screen, isolated
/// preferences, a private pasteboard), renders PNGs of each state into <dir>, prints PASS/FAIL
/// lines and exits non-zero on any failure.
enum SelfTest {
    private static var failures = 0
    private static var out = URL(fileURLWithPath: NSTemporaryDirectory())

    static func check(_ ok: Bool, _ name: String, _ detail: @autoclosure () -> String = "") {
        print(ok ? "PASS" : "FAIL", name, ok ? "" : detail())
        if !ok { failures += 1 }
    }

    static func wait(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    static func key(_ code: Int, _ chars: String = "", flags: NSEvent.ModifierFlags = []) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars,
                         isARepeat: false, keyCode: UInt16(code))!
    }

    static func snapshot(_ name: String) {
        guard let view = ReaderController.shared.panel?.readerView else { return }
        view.display()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
    }

    /// `--selftest-live`: puts the reader on screen for a moment and checks that the panel
    /// takes the keyboard without Monoword becoming the active app.
    static func runLive() {
        let suite = "Monoword.selftest"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = Settings(defaults: UserDefaults(suiteName: suite)!)
        Settings.shared = settings
        settings.autoStart = false
        let reader = ReaderController.shared
        let before = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        reader.open(text: "Live check of the reader panel.", source: .sample)
        wait(0.5)
        let panel = reader.panel!
        check(panel.isVisible, "panel is on screen")
        check(panel.isKeyWindow, "panel is the key window (gets the keyboard)")
        let after = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        print("info app active: \(NSApp.isActive) (true means the activation fallback was needed); front before: \(before)")
        print("info front app: \(after); panel frame: \(panel.frame)")
        // Rhythm: identical words at 700 wpm on the frame clock. Each change should land on a whole
        // number of frames, and the mean should match the speed.
        settings.wpm = 700
        settings.punctuationPause = 0
        settings.adaptivePacing = false
        settings.rampUp = false
        settings.chunkSize = 1
        reader.open(text: String(repeating: "word ", count: 60), source: .sample)
        reader.recordChanges = true
        reader.play()
        wait(2.5)
        reader.pause()
        let times = reader.changeTimes
        reader.recordChanges = false
        let intervals = zip(times.dropFirst(), times).map { $0 - $1 }.dropFirst()   // skip the first (start-up)
        let frame = 1.0 / Double(NSScreen.main?.maximumFramesPerSecond ?? 60)
        let offGrid = intervals.filter { abs($0 / frame - ($0 / frame).rounded()) * frame > 0.004 }
        let mean = intervals.isEmpty ? 0 : intervals.reduce(0, +) / Double(intervals.count)
        print(String(format: "info rhythm: %d changes, mean %.1f ms (ideal %.1f), frames %@", intervals.count, mean * 1000,
                     60_000.0 / 700, intervals.map { String(Int(($0 / frame).rounded())) }.joined(separator: " ")))
        check(intervals.count >= 15, "frame clock advances", "\(intervals.count)")
        check(offGrid.isEmpty, "every word change lands on a frame boundary", "\(offGrid.count) off grid")
        check(abs(mean - 60.0 / 700) < 0.006, "average speed matches 700 wpm", String(format: "%.1f ms", mean * 1000))

        // Real speed on the real screen: prose with pauses at 1000 wpm, adaptive, auto grouping.
        // Words read per minute of wall time must match the setting (frame steps included).
        settings.wpm = 1000
        settings.punctuationPause = 1
        settings.adaptivePacing = true
        settings.rampUp = true
        settings.chunkSize = 0
        let prose = String(repeating: "The committee met on Tuesday to review the budget, which had grown by almost a third since the previous year. Several members argued that the increase was justified; others wanted cuts. ", count: 4)
        reader.open(text: prose, source: .sample)
        let words = reader.session?.document.wordCount ?? 0
        let started = Date()
        reader.play()
        while !reader.isFinished && Date().timeIntervalSince(started) < 15 { wait(0.02) }
        let real = Double(words) / reader.readingTime * 60
        print(String(format: "info real speed at 1000 wpm: %d words in %.2f s = %.0f wpm", words, reader.readingTime, real))
        check(reader.isFinished && abs(real - 1000) / 1000 < 0.03, "real speed on screen matches 1000 wpm (±3%)",
              String(format: "%.0f wpm", real))

        reader.close()
        wait(0.3)
        check(!panel.isVisible, "esc/close hides the panel")
        let restored = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        check(restored == before, "focus goes back to the app he was in", "\(before) -> \(restored)")
        UserDefaults().removePersistentDomain(forName: suite)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }

    static func run(outputDirectory: URL) {
        out = outputDirectory
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let suite = "Monoword.selftest"
        UserDefaults().removePersistentDomain(forName: suite)
        let settings = Settings(defaults: UserDefaults(suiteName: suite)!)
        Settings.shared = settings
        settings.autoStart = false
        settings.closeWhenDone = false
        settings.wpm = 400
        check(settings.chunkSize == 0, "auto grouping is the default")
        settings.chunkSize = 1
        let reader = ReaderController.shared
        reader.headless = true
        if let url = AppDelegate.frequencyListURL, let list = try? String(contentsOf: url, encoding: .utf8) {
            ReaderController.frequency = FrequencyTable(listText: list)
        }
        check(ReaderController.frequency?.count == 50_000, "word frequency list loads",
              "\(ReaderController.frequency?.count ?? 0)")

        let sample = """
        Speed reading works by removing eye movement. Each word appears at the same spot, \
        so your eyes stay still while the text flows past. Press space to pause and see the sentence around it.

        The second paragraph has a link https://www.example.com/a/b and an incomprehensibilities test.
        """
        reader.open(text: sample, source: .selection)
        check(reader.session?.currentText == "Speed", "opens on first word", reader.session?.currentText ?? "nil")
        check(!reader.isPlaying, "autoStart off stays paused")
        snapshot("01-paused-first-word")

        reader.handleKey(key(kVK_Space, " "))
        check(reader.isPlaying, "space starts")
        wait(1.2)
        let advanced = reader.session?.index ?? 0
        // 400 wpm = 150 ms a plain word; with the ease-in, 1.2 s is about 5 to 8 tokens.
        check((4...9).contains(advanced), "clock advances at the set pace", "index \(advanced)")
        snapshot("02-playing")
        reader.handleKey(key(kVK_Space, " "))
        check(!reader.isPlaying, "space pauses")
        let pausedAt = reader.session?.index ?? -1
        wait(0.4)
        check(reader.session?.index == pausedAt, "paused clock is stopped")
        snapshot("03-paused-context")

        reader.handleKey(key(kVK_UpArrow))
        check(settings.wpm == 425, "up arrow +25", "\(settings.wpm)")
        reader.handleKey(key(kVK_DownArrow, flags: .shift))
        check(settings.wpm == 325, "shift down -100", "\(settings.wpm)")
        settings.wpm = 400

        reader.handleKey(key(kVK_RightArrow))
        let afterForward = reader.session.map { $0.document.tokens[$0.index] }
        check(afterForward?.text == "Each", "right arrow to next sentence", afterForward?.text ?? "nil")
        reader.handleKey(key(kVK_LeftArrow))
        check(reader.session?.currentText == "Speed", "left arrow at sentence start goes to previous")
        reader.handleKey(key(kVK_RightArrow, flags: .shift))
        check(reader.session?.currentText == "reading", "shift right steps one word")

        reader.handleKey(key(kVK_ANSI_3, "3"))
        check(settings.chunkSize == 3 && reader.session?.currentText == "reading works by", "3 shows three words",
              reader.session?.currentText ?? "nil")
        snapshot("04-three-words")
        reader.handleKey(key(kVK_ANSI_1, "1"))
        check(reader.session?.currentText == "reading", "1 back to single words")
        reader.handleKey(key(kVK_ANSI_A, "a"))
        check(settings.chunkSize == 0 && reader.session?.currentText == "reading", "a switches to auto grouping",
              reader.session?.currentText ?? "nil")
        reader.handleKey(key(kVK_ANSI_1, "1"))

        reader.handleKey(key(kVK_ANSI_Slash, "?"))
        check(reader.showHelp, "? shows the keys")
        snapshot("05-help")
        reader.handleKey(key(kVK_Escape))
        check(!reader.showHelp, "esc closes help first")

        settings.theme = .light
        wait(0.05)
        snapshot("06-light")
        settings.theme = .sepia
        settings.font = .serif
        wait(0.05)
        snapshot("07-sepia-serif")
        settings.theme = .dark
        settings.font = .system

        // Long word, emoji, link.
        reader.open(text: "incomprehensibilities 🎉 https://x.com/someone/status/123", source: .clipboard)
        snapshot("08-long-word-piece")
        reader.handleKey(key(kVK_RightArrow, flags: .shift))
        reader.handleKey(key(kVK_RightArrow, flags: .shift))
        check(reader.session?.currentText == "🎉", "emoji is its own token", reader.session?.currentText ?? "nil")
        reader.handleKey(key(kVK_RightArrow, flags: .shift))
        check(reader.session?.currentText == "x.com", "link shown as host", reader.session?.currentText ?? "nil")
        snapshot("09-link")

        // Banner when Accessibility is missing (only meaningful while it is off).
        reader.open(text: "Reading from the clipboard because Accessibility is off.", source: .clipboard, limited: true)
        snapshot("10-banner")

        reader.openMessage("Nothing selected", detail: "Select some text in any app, then press ⌃⌥R.", limited: false)
        snapshot("11-message")

        // Finishing.
        settings.wpm = 1500
        settings.rampUp = false
        reader.open(text: "Short text to finish quickly. Done soon.", source: .selection)
        reader.play()
        wait(1.5)
        check(reader.isFinished, "reaches the end")
        snapshot("12-done")
        reader.handleKey(key(kVK_Space, " "))
        check(reader.isPlaying && !reader.isFinished, "space after the end reads again")
        reader.close()
        settings.wpm = 400
        settings.rampUp = true

        // Big text stays responsive.
        let big = String(repeating: "This is a fairly ordinary sentence with some words, and a pause. ", count: 4000)
        let t0 = Date()
        reader.open(text: big, source: .clipboard)
        let openTime = Date().timeIntervalSince(t0)
        check(openTime < 1.5, "48k words open fast", String(format: "%.2fs", openTime))
        print(String(format: "info open 48k words: %.3fs", openTime))
        reader.handleKey(key(kVK_RightArrow))
        snapshot("13-big")
        reader.close()

        // Resume point.
        check(settings.lastText != nil && settings.lastIndex > 0, "closing early saves a resume point",
              "\(settings.lastIndex)")

        // Review fixes: messages survive key presses; empty text says so.
        reader.openMessage("Nothing selected", detail: "detail", limited: false)
        reader.handleKey(key(kVK_UpArrow))
        check(reader.panel?.readerView.state.message == "Nothing selected", "message survives a key press")
        settings.wpm = 400
        reader.open(text: "--- • |", source: .clipboard)
        check(reader.panel?.readerView.state.message == "Nothing to read", "wordless text says nothing to read")

        // Finishing a short text keeps the long text's resume point.
        let longText = String(repeating: "Words for a long article that he will come back to later. ", count: 20)
        reader.open(text: longText, source: .selection)
        reader.handleKey(key(kVK_RightArrow)); reader.handleKey(key(kVK_RightArrow))
        reader.open(text: "Quick tweet. Done.", source: .selection)   // replacing it saves the place
        check(settings.lastText == longText, "opening another text saves the long one's place")
        settings.wpm = 1500
        settings.rampUp = false
        reader.play()
        wait(1.0)
        check(reader.isFinished && settings.lastText == longText, "finishing a short text keeps the long resume point")

        // Restart while playing resets the reading clock.
        reader.open(text: String(repeating: "word ", count: 60), source: .selection)
        reader.play()
        wait(1.5)   // 60 words at 1500 wpm take about 2.5 s, so this is mid-text
        reader.handleKey(key(kVK_ANSI_R, "r"))
        check(reader.isPlaying && (reader.session?.index ?? 99) < 15, "r restarts while playing")
        wait(3.5)
        check(reader.isFinished, "restarted text finishes")
        // Without the fix the 1.5 s before the restart is counted too (about 4 s in all).
        check(reader.readingTime < 3.2, "restart resets the reading clock", String(format: "%.2fs", reader.readingTime))
        reader.close()
        settings.wpm = 400
        settings.rampUp = true

        // Right ⌘ double tap, fed synthetic modifier events (the real ones need Accessibility).
        var fired = 0
        var systemSawKey = false
        let realCounter = ModifierTapMonitor.keyOrClickSince
        ModifierTapMonitor.keyOrClickSince = { _ in systemSawKey }
        let monitor = ModifierTapMonitor.shared
        monitor.onDoubleTap = { fired += 1 }
        func flags(_ keyCode: Int, _ raw: UInt, _ t: TimeInterval) -> NSEvent {
            NSEvent.keyEvent(with: .flagsChanged, location: .zero, modifierFlags: NSEvent.ModifierFlags(rawValue: raw),
                             timestamp: t, windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
                             isARepeat: false, keyCode: UInt16(keyCode))!
        }
        let cmd = NSEvent.ModifierFlags.command.rawValue
        let base = ProcessInfo.processInfo.systemUptime
        for (code, raw, dt) in [(kVK_RightCommand, cmd | 0x10, 0.0), (kVK_RightCommand, UInt(0), 0.08),
                                (kVK_RightCommand, cmd | 0x10, 0.22), (kVK_RightCommand, UInt(0), 0.30)] {
            monitor.handle(flags(code, raw, base + dt))
        }
        check(fired == 1, "right ⌘ double tap fires", "\(fired)")
        for (code, raw, dt) in [(kVK_Command, cmd | 0x08, 1.0), (kVK_Command, UInt(0), 1.08),
                                (kVK_Command, cmd | 0x08, 1.22), (kVK_Command, UInt(0), 1.30)] {
            monitor.handle(flags(code, raw, base + dt))
        }
        check(fired == 1, "left ⌘ double tap is ignored", "\(fired)")
        monitor.handle(flags(kVK_RightCommand, cmd | 0x10, base + 2.0))
        monitor.handle(flags(kVK_RightCommand, 0, base + 2.08))
        monitor.handle(flags(kVK_RightCommand, cmd | 0x10, base + 2.2))
        monitor.handle(key(kVK_ANSI_C, "c", flags: .command))
        monitor.handle(flags(kVK_RightCommand, 0, base + 2.3))
        check(fired == 1, "right ⌘ + C is not a double tap", "\(fired)")
        // A key the monitor never saw (consumed by the system) but the system counter did.
        systemSawKey = true
        for (code, raw, dt) in [(kVK_RightCommand, cmd | 0x10, 3.0), (kVK_RightCommand, UInt(0), 3.08),
                                (kVK_RightCommand, cmd | 0x10, 3.22), (kVK_RightCommand, UInt(0), 3.30)] {
            monitor.handle(flags(code, raw, base + dt))
        }
        check(fired == 1, "a tap with an unseen key pressed is not a double tap", "\(fired)")
        systemSawKey = false
        ModifierTapMonitor.keyOrClickSince = realCounter
        monitor.onDoubleTap = nil

        // Clipboard save and restore, on a private pasteboard (never his real clipboard).
        let pb = NSPasteboard(name: NSPasteboard.Name("Monoword.selftest.\(getpid())"))
        pb.clearContents()
        let custom = NSPasteboard.PasteboardType("com.example.custom")
        let item = NSPasteboardItem()
        item.setString("original", forType: .string)
        item.setData(Data([1, 2, 3]), forType: custom)
        pb.writeObjects([item])
        let saved = SelectionGrabber.snapshot(pb)
        pb.clearContents()
        pb.setString("selected words", forType: .string)
        check(SelectionGrabber.clipboardText(pb) == "selected words", "reads copied text")
        SelectionGrabber.restore(saved, to: pb)
        check(pb.string(forType: .string) == "original" && pb.data(forType: custom) == Data([1, 2, 3]),
              "restores the old clipboard with every type")
        check(pb.types?.contains(NSPasteboard.PasteboardType("org.nspasteboard.TransientType")) == true,
              "restore is marked transient for clipboard managers")
        pb.releaseGlobally()

        // RTF-only clipboard.
        let rtfBoard = NSPasteboard(name: NSPasteboard.Name("Monoword.selftest.rtf.\(getpid())"))
        rtfBoard.clearContents()
        let rtf = NSAttributedString(string: "rich text only").rtf(from: NSRange(location: 0, length: 14), documentAttributes: [:])!
        rtfBoard.setData(rtf, forType: .rtf)
        check(SelectionGrabber.clipboardText(rtfBoard) == "rich text only", "reads RTF-only clipboard")
        rtfBoard.releaseGlobally()

        // A hotkey nobody uses, registered and released.
        let odd = Shortcut(keyCode: UInt32(kVK_F19), modifiers: UInt32(cmdKey | optionKey | controlKey | shiftKey))
        check(HotKeyCenter.shared.register(id: 99, shortcut: odd, action: {}), "registers a global hotkey")
        HotKeyCenter.shared.unregister(id: 99)
        check(Shortcut.defaultRead.displayString == "⌃⌥R", "default shortcut reads ⌃⌥R", Shortcut.defaultRead.displayString)

        let c = KeyNames.keyCode(forCommandCharacter: "c", fallback: 255)
        check(c != 255, "finds the key that types ⌘C", "\(c)")
        print("info accessibility trusted: \(SelectionGrabber.isTrusted)")

        // Settings window, rendered off screen.
        let hosting = NSHostingView(rootView: SettingsView(settings: settings))
        hosting.frame = NSRect(x: 0, y: 0, width: 520, height: 640)
        let window = NSWindow(contentRect: hosting.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = hosting
        hosting.layoutSubtreeIfNeeded()
        wait(0.3)
        if let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) {
            hosting.cacheDisplay(in: hosting.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("20-settings.png"))
        }

        UserDefaults().removePersistentDomain(forName: suite)
        print(failures == 0 ? "ALL PASS" : "\(failures) FAILED")
        exit(failures == 0 ? 0 : 1)
    }
}
