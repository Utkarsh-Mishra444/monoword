import AppKit
import Carbon.HIToolbox
import Combine
import QuartzCore
import MonowordCore

/// A floating panel that takes the keyboard without activating Monoword (like Spotlight), so the
/// app he was reading in stays in front and gets focus back the moment the reader closes.
final class ReaderPanel: NSPanel {
    let readerView = ReaderView()
    var keyHandler: ((NSEvent) -> Bool)?

    init() {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 720, height: 250),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isReleasedWhenClosed = false
        animationBehavior = .utilityWindow
        contentView = readerView
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, keyHandler?(event) == true { return }
        super.sendEvent(event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        keyHandler?(event) == true || super.performKeyEquivalent(with: event)
    }
}

/// Dims the screen behind the reader (optional, Settings > Dim the screen).
final class DimWindow: NSWindow {
    init(screen: NSScreen) {
        super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        level = .floating
        backgroundColor = NSColor.black.withAlphaComponent(0.45)
        isOpaque = false
        ignoresMouseEvents = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }
}

/// Owns the reading session and its clock, turns keys into moves, and feeds the view.
final class ReaderController: NSObject, NSWindowDelegate {
    static let shared = ReaderController()

    /// The self-test renders without putting a window on screen.
    var headless = false

    /// Seconds the first word sits still after opening, before the words start moving (autoStart).
    static let settleBeforeStart: TimeInterval = 0.45

    private(set) var panel: ReaderPanel?
    private(set) var session: ReadingSession?
    private(set) var isPlaying = false
    private(set) var isFinished = false
    private(set) var source: TextSource = .selection
    private(set) var showHelp = false
    private var rawText = ""
    private var message: String?
    private var messageDetail: String?
    private var limited = false
    private var rampStep = 0
    private var timer: Timer?
    private var startTimer: Timer?
    private var closeTimer: Timer?
    private var flashTimer: Timer?
    private var speedFlash = false
    private var playStartedAt: Date?
    private(set) var readingTime: TimeInterval = 0
    private var dim: DimWindow?
    private var previousApp: NSRunningApplication?
    private var activatedSelf = false
    private var pacing: Pacing?
    private var pacingRebuild: DispatchWorkItem?
    /// Seconds from each token to the end at `remainingWPM`, for the "time left" readout.
    private var remainingSuffix: [Double] = []
    private var remainingWPM = 0

    /// Word frequencies for adaptive pacing, loaded once in the background at launch.
    static var frequency: FrequencyTable?
    private var cancellables = Set<AnyCancellable>()

    private var settings: Settings { Settings.shared }

    var isVisible: Bool { panel?.isVisible == true }

    // MARK: - Opening and closing

    func open(text: String, source: TextSource, limited: Bool = false, startIndex: Int = 0) {
        saveResumePoint()   // the text being replaced may be a long one worth coming back to
        closeTimer?.invalidate()
        startTimer?.invalidate()
        stopClock()
        self.source = source
        self.rawText = text
        self.limited = limited && !SelectionGrabber.isTrusted
        showHelp = false
        isFinished = false
        readingTime = 0
        message = nil
        messageDetail = nil
        let document = Document(raw: text, options: settings.tokenizer)
        session = document.isEmpty ? nil : ReadingSession(document: document, chunkSize: settings.chunkSize,
                                                          startIndex: startIndex)
        if document.isEmpty {
            message = "Nothing to read"
            messageDetail = "The text has no words in it."
        }
        rebuildPacing()
        Log.app.notice("open source=\(source.rawValue, privacy: .public) words=\(document.wordCount) limited=\(self.limited)")
        ensurePanel()
        layoutPanel(reposition: !isVisible)
        render()
        show()
        if session != nil && settings.autoStart {
            // A beat to settle the eyes on the first word before the words start moving.
            startTimer = Timer(timeInterval: Self.settleBeforeStart, repeats: false) { [weak self] _ in self?.play() }
            RunLoop.main.add(startTimer!, forMode: .common)
        }
    }

    /// Shows a message instead of words (nothing selected, permission needed...).
    func openMessage(_ message: String, detail: String?, limited: Bool) {
        saveResumePoint()
        closeTimer?.invalidate()
        startTimer?.invalidate()
        stopClock()
        session = nil
        rawText = ""
        isFinished = false
        showHelp = false
        self.message = message
        self.messageDetail = detail
        self.limited = limited && !SelectionGrabber.isTrusted
        Log.app.notice("message \(message, privacy: .public)")
        ensurePanel()
        layoutPanel(reposition: !isVisible)
        render()
        show()
    }

    func close() {
        startTimer?.invalidate()
        closeTimer?.invalidate()
        if isPlaying { pause() }
        saveResumePoint()
        releaseFrameClock()
        panel?.orderOut(nil)
        dim?.orderOut(nil)
        if activatedSelf {
            activatedSelf = false
            // Only hand focus back if Monoword still has it (he may have clicked elsewhere since).
            if NSApp.isActive { previousApp?.activate(options: []) }
        }
    }

    private func show() {
        guard let panel, !headless else { return }
        if settings.dimScreen, let screen = panel.screen ?? NSScreen.main {
            if dim == nil || dim?.frame != screen.frame { dim = DimWindow(screen: screen) }
            dim?.orderFrontRegardless()
        }
        let front = NSWorkspace.shared.frontmostApplication
        if front?.processIdentifier != ProcessInfo.processInfo.processIdentifier { previousApp = front }
        panel.orderFrontRegardless()
        panel.makeKey()
        // A non-activating panel normally takes the keyboard on its own. If the system did not
        // let it, activate Monoword so the keys still work, and hand focus back on close.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self, let panel = self.panel, panel.isVisible else { return }
            if panel.isKeyWindow {
                Log.app.notice("panel is key without activation")
                return
            }
            Log.app.notice("panel not key after 150 ms: activating Monoword")
            self.activatedSelf = true
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKey()
        }
    }

    private func ensurePanel() {
        guard panel == nil else { return }
        let panel = ReaderPanel()
        panel.delegate = self
        panel.keyHandler = { [weak self] event in self?.handleKey(event) ?? false }
        let view = panel.readerView
        view.onToggle = { [weak self] in self?.togglePlay() }
        view.onAllow = { [weak self] in
            self?.pause()
            SelectionGrabber.requestAccess()
        }
        view.onScrub = { [weak self] delta in self?.scrub(delta) }
        self.panel = panel
        NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.activatedSelf = false }
        settings.objectWillChange
            .sink { [weak self] in DispatchQueue.main.async { self?.settingsChanged() } }
            .store(in: &cancellables)
    }

    private func settingsChanged() {
        guard let panel, panel.isVisible || headless else { return }
        if let session, session.chunkSize != settings.chunkSize { session.chunkSize = settings.chunkSize }
        var current = settings.timing
        current.wpm = 0
        var built = pacing?.options
        built?.wpm = 0
        if session != nil && built != current {
            // Debounced: dragging the punctuation slider would otherwise rebuild on every tick.
            pacingRebuild?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.rebuildPacing()
                self?.render()
            }
            pacingRebuild = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.15, execute: work)
        }
        layoutPanel(reposition: false)
        render()
    }

    /// Sizes the panel for the font size and, when asked, centres it a little above the middle of
    /// the screen the mouse is on.
    private func layoutPanel(reposition: Bool) {
        guard let panel else { return }
        let view = panel.readerView
        view.theme = settings.theme
        view.wordFont = settings.font.font(size: CGFloat(settings.fontSize))
        view.showGuides = settings.showGuides

        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(max(560, CGFloat(settings.fontSize) * 15.5), visible.width - 40)
        let height = ReaderView.preferredHeight(fontSize: CGFloat(settings.fontSize))
        var frame = panel.frame
        if reposition {
            frame = NSRect(x: visible.midX - width / 2, y: visible.minY + visible.height * 0.58 - height / 2,
                           width: width, height: height)
        } else {
            // Keep the top edge where it is.
            frame = NSRect(x: frame.midX - width / 2, y: frame.maxY - height, width: width, height: height)
        }
        panel.setFrame(frame.integral, display: true)
        panel.invalidateShadow()
    }

    // MARK: - The clock

    func play() {
        startTimer?.invalidate()
        guard let session, !isPlaying else { return }
        if isFinished { restart(); return }
        isPlaying = true
        rampStep = 0
        clockStart = (session.index, 0)
        quantizer.reset()
        lastFrameTimestamp = 0
        playStartedAt = Date()
        showHelp = false
        render()
        scheduleNext(for: session)
    }

    func pause() {
        startTimer?.invalidate()
        guard isPlaying else { return }
        stopClock()
        render()
    }

    func togglePlay() {
        if isFinished { restart() } else if isPlaying { pause() } else { play() }
    }

    private func stopClock() {
        timer?.invalidate()
        timer = nil
        frameClock?.isPaused = true
        if isPlaying, let started = playStartedAt { readingTime += Date().timeIntervalSince(started) }
        playStartedAt = nil
        isPlaying = false
    }

    /// Where (token, ease-in step) the current run of reading started: the speed holds from there
    /// to the end. Set on play and on every jump.
    private var clockStart = (index: 0, rampStep: 0)
    /// The timing clock for the current text, speed, grouping and start point (solved once each).
    private var cachedClock: (wpm: Int, chunk: Int, start: Int, rampStep: Int, clock: Pacing.Clock)?

    private func currentClock() -> Pacing.Clock {
        if let c = cachedClock, c.wpm == settings.wpm, c.chunk == settings.chunkSize,
           c.start == clockStart.index, c.rampStep == clockStart.rampStep {
            return c.clock
        }
        // Every flash from the start point, as the reader will show it, so the solve can honour the
        // display's minimum flash (2 frames) and still land on the speed.
        let flashes = session?.chunks(from: clockStart.index, count: .max) ?? []
        let clock = pacing?.clock(forWPM: Double(settings.wpm), from: clockStart.index, flashes: flashes,
                                  rampStep: clockStart.rampStep,
                                  minimumFlash: Double(FrameQuantizer.minimumFrames) * quantizer.frameDuration)
            ?? Pacing.Clock(base: 60.0 / Double(settings.wpm), pauseScale: 1)
        cachedClock = (settings.wpm, settings.chunkSize, clockStart.index, clockStart.rampStep, clock)
        remainingWPM = 0
        return clock
    }

    /// Per-token timing for the current document and settings (speed is applied at each step).
    private func rebuildPacing() {
        remainingWPM = 0
        cachedClock = nil
        guard let session else { pacing = nil; return }
        pacing = Pacing(document: session.document, options: settings.timing, frequency: Self.frequency)
    }

    // MARK: Frame clock
    //
    // Words change in step with the display: each chunk is held for a whole number of frames (at
    // least 2), and the rounding left over is carried into the next chunk, so the average speed is
    // exact and the rhythm even. A free-running timer lands each word on a varying number of
    // frames (on a 60 Hz screen at 700 wpm a plain word needs 5.14 frames, so 5 or 6; the shortest
    // words 3 or 4).

    private var frameClock: CADisplayLink?
    private var quantizer = FrameQuantizer(frameDuration: 1.0 / 60)
    private var frameDuration: Double { quantizer.frameDuration }
    private var nextChangeAt: CFTimeInterval = 0
    private var lastFrameTimestamp: CFTimeInterval = 0

    private func scheduleNext(for session: ReadingSession) {
        timer?.invalidate()
        if pacing == nil { rebuildPacing() }
        let interval = pacing?.seconds(for: session.currentRange, clock: currentClock(), rampStep: rampStep) ?? 0.15
        if manualClock {
            let frames = quantizer.frames(for: interval)
            manualHold = (frames, Double(frames) * frameDuration)
            return
        }
        if !headless, let clock = ensureFrameClock() {
            let frames = quantizer.frames(for: interval)
            let base = clock.isPaused || lastFrameTimestamp == 0 ? CACurrentMediaTime() + frameDuration : lastFrameTimestamp
            nextChangeAt = base + Double(frames) * frameDuration
            clock.isPaused = false
            return
        }
        let t = Timer(timeInterval: interval, repeats: false) { [weak self] _ in self?.tick() }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func ensureFrameClock() -> CADisplayLink? {
        if let frameClock { return frameClock }
        guard let view = panel?.readerView, view.window != nil else { return nil }
        let link = view.displayLink(target: self, selector: #selector(frameTick(_:)))
        link.add(to: .main, forMode: .common)
        link.isPaused = true
        frameClock = link
        return link
    }

    @objc private func frameTick(_ link: CADisplayLink) {
        guard isPlaying else { link.isPaused = true; return }
        let duration = link.targetTimestamp - link.timestamp
        if duration > 0.002 && duration < 0.1 { quantizer.frameDuration = duration }
        // targetTimestamp is when the frame being prepared reaches the screen.
        lastFrameTimestamp = link.targetTimestamp
        if link.targetTimestamp >= nextChangeAt - frameDuration / 2 { tick() }
    }

    private func releaseFrameClock() {
        frameClock?.invalidate()
        frameClock = nil
        lastFrameTimestamp = 0
    }

    /// `Monoword --render` steps the clock by hand. With this on no timer or display link runs: each
    /// flash's hold, in whole frames of the frame clock (60 Hz when headless) exactly as
    /// `scheduleNext` gives them to it, waits in `manualHold` until `manualTick()` makes the step a
    /// clock tick makes. Off in the app.
    var manualClock = false
    private(set) var manualHold = (frames: 0, seconds: 0.0)
    func manualTick() { tick() }

    /// Self-test instrumentation: when on, the time of every word change is recorded.
    var recordChanges = false
    private(set) var changeTimes: [CFTimeInterval] = []

    private func tick() {
        guard isPlaying, let session else { return }
        if recordChanges { changeTimes.append(CACurrentMediaTime()) } else if !changeTimes.isEmpty { changeTimes = [] }
        rampStep += 1
        if session.advance() {
            render()
            scheduleNext(for: session)
        } else {
            finish()
        }
    }

    private func finish() {
        stopClock()
        isFinished = true
        if settings.lastText == rawText { settings.lastText = nil }
        render()
        if settings.closeWhenDone && !headless {
            closeTimer = Timer(timeInterval: 2.5, repeats: false) { [weak self] _ in self?.close() }
            RunLoop.main.add(closeTimer!, forMode: .common)
        }
    }

    func restart() {
        closeTimer?.invalidate()
        guard let session else { return }
        stopClock()
        isFinished = false
        readingTime = 0
        session.restart()
        render()
        play()
    }

    /// After a jump while playing, restart the clock with a short ease-in.
    private func moved() {
        closeTimer?.invalidate()
        isFinished = false
        if isPlaying, let session {
            quantizer.reset()
            lastFrameTimestamp = 0
            rampStep = Pacing.rampWords - 2
            clockStart = (session.index, rampStep)
            scheduleNext(for: session)
        }
        render()
    }

    private func scrub(_ delta: Int) {
        guard let session else { return }
        pause()
        session.step(delta)
        moved()
    }

    // MARK: - Keys

    /// Returns true when the key was used.
    @discardableResult
    func handleKey(_ event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let shift = flags.contains(.shift)
        if flags.contains(.command) {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "w", ".", "q": close(); return true
            case ",": close(); AppDelegate.shared?.openSettings(); return true
            default: return false
            }
        }
        switch Int(event.keyCode) {
        case kVK_Escape:
            if showHelp { showHelp = false; render() } else { close() }
            return true
        case kVK_Space, kVK_Return, kVK_ANSI_KeypadEnter:
            togglePlay(); return true
        case kVK_LeftArrow:
            guard let session else { return true }
            if isFinished { isFinished = false; session.rewindSentence(); moved(); return true }
            if shift { pause(); session.step(-1) } else { session.rewindSentence() }
            moved(); return true
        case kVK_RightArrow:
            guard let session else { return true }
            if shift { pause(); session.step(1) } else { session.forwardSentence() }
            moved(); return true
        case kVK_UpArrow:
            changeSpeed(shift ? 100 : 25); return true
        case kVK_DownArrow:
            changeSpeed(shift ? -100 : -25); return true
        default:
            break
        }
        switch event.charactersIgnoringModifiers?.lowercased() {
        case "r":
            restart(); return true
        case "0", "a", "1", "2", "3":
            settings.chunkSize = Int(event.charactersIgnoringModifiers!) ?? 0
            session?.chunkSize = settings.chunkSize
            flashSpeed(); return true
        case "?", "/", "h":
            showHelp.toggle()
            if showHelp && isPlaying { pause() }
            render(); return true
        case "[", "-":
            settings.fontSize = max(24, settings.fontSize - 4); return true
        case "]", "=", "+":
            settings.fontSize = min(96, settings.fontSize + 4); return true
        case "t":
            let all = Theme.allCases
            settings.theme = all[(all.firstIndex(of: settings.theme)! + 1) % all.count]
            return true
        default:
            return false
        }
    }

    private func changeSpeed(_ delta: Int) {
        settings.adjustWPM(by: delta)
        flashSpeed()
    }

    private func flashSpeed() {
        speedFlash = true
        flashTimer?.invalidate()
        flashTimer = Timer(timeInterval: 0.9, repeats: false) { [weak self] _ in
            self?.speedFlash = false
            self?.render()
        }
        RunLoop.main.add(flashTimer!, forMode: .common)
        render()
    }

    // MARK: - Window

    func windowDidResignKey(_ notification: Notification) {
        // He clicked into another app: hold the place instead of reading on unseen.
        if isPlaying { pause() }
    }

    // MARK: - Resume

    private func saveResumePoint() {
        guard let session, !isFinished, !rawText.isEmpty, source != .sample else { return }
        // Only worth resuming if there is a meaningful amount left.
        if session.document.wordCount < 25 || session.progress > 0.97 { return }
        settings.lastText = rawText
        settings.lastIndex = session.index
        settings.lastProgress = session.progress
    }

    // MARK: - Rendering

    /// Time to the end from `index`, including the ease-in still to come (a full one after a pause).
    private func remainingSeconds(from index: Int) -> TimeInterval {
        guard let pacing, let session else { return 0 }
        let clock = currentClock()
        let step = isPlaying ? rampStep : 0
        let ramp = pacing.rampExtra(clock, session.chunks(from: index, count: Pacing.rampWords), step: step)
        return suffixSeconds(from: index) + ramp
    }

    private func suffixSeconds(from index: Int) -> TimeInterval {
        guard let pacing else { return 0 }
        if remainingWPM != settings.wpm || remainingSuffix.count != pacing.slots.count + 1 {
            var suffix = [Double](repeating: 0, count: pacing.slots.count + 1)
            for k in stride(from: pacing.slots.count - 1, through: 0, by: -1) {
                suffix[k] = suffix[k + 1] + pacing.seconds(for: k..<(k + 1), clock: currentClock())
            }
            remainingSuffix = suffix
            remainingWPM = settings.wpm
        }
        return index < remainingSuffix.count ? remainingSuffix[index] : 0
    }

    static func duration(_ seconds: TimeInterval) -> String {
        seconds < 59.5 ? "\(Int(seconds.rounded())) s" : clock(seconds)
    }

    static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds.rounded())
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
                         : String(format: "%d:%02d", s / 60, s % 60)
    }

    func render() {
        guard let panel else { return }
        var state = ReaderView.State()
        state.playing = isPlaying
        state.showHelp = showHelp
        state.speedFlash = speedFlash
        let chunk = settings.chunkSize == 0 ? " · auto" : settings.chunkSize > 1 ? " · \(settings.chunkSize) words" : ""
        state.speed = "\(settings.wpm) wpm\(chunk)"
        // The number shown is the speed he will actually get: when this text cannot reach the
        // setting on this display (flashes at their 2-frame minimum), say so with the real maximum.
        if session != nil, pacing != nil, let reachable = currentClock().reachableWPM {
            state.speed = "\(settings.wpm) wpm · this text max \(Int(reachable.rounded(.down)))\(chunk)"
        }
        if limited {
            state.banner = "Reading the clipboard. Allow Accessibility to read selected text directly."
        }

        if let message {
            state.message = message
            state.messageDetail = messageDetail
        } else if let session {
            let doc = session.document
            state.header = "\(source.rawValue) · \(doc.wordCount.formatted()) words"
            if isFinished {
                let words = doc.wordCount
                var detail = "\(words.formatted()) words in \(Self.duration(readingTime))"
                if readingTime >= 3 {
                    detail += " · \(Int((Double(words) / readingTime * 60).rounded())) wpm measured"
                }
                state.message = "Done"
                state.messageDetail = detail + "\nspace reads it again · ← goes back"
                state.progress = 1
                state.footer = "finished"
            } else {
                let range = session.currentRange
                let text = session.currentText
                state.word = text
                state.isLink = doc.tokens[range.lowerBound].isLink
                state.progress = session.progress
                let left = remainingSeconds(from: range.lowerBound)
                state.footer = "\(Self.clock(left)) left · \(Int((state.progress * 100).rounded(.down)))%"
                if !isPlaying { state.context = contextString(session) }
            }
        }
        panel.readerView.state = state
    }

    /// The sentence around the current words, with them highlighted, for a glance while paused.
    private func contextString(_ session: ReadingSession) -> NSAttributedString {
        let doc = session.document
        let ns = doc.text as NSString
        let range = session.currentRange
        let current = NSUnionRange(doc.tokens[range.lowerBound].range, doc.tokens[range.upperBound - 1].range)
        let s = doc.tokens[range.lowerBound].sentence
        let firstToken = doc.sentenceStarts[max(0, s - 1)]
        let lastToken = s + 2 < doc.sentenceStarts.count ? doc.sentenceStarts[s + 2] - 1 : doc.tokens.count - 1
        var window = NSUnionRange(doc.tokens[firstToken].range, doc.tokens[lastToken].range)
        // Keep it to about three lines, centred on the current words.
        let budget = 230
        if window.length > budget {
            let start = max(window.location, min(current.location - budget / 2, NSMaxRange(window) - budget))
            window = NSRange(location: start, length: min(budget, NSMaxRange(window) - start))
            window = ns.rangeOfComposedCharacterSequences(for: window)
        }
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineBreakMode = .byWordWrapping
        style.lineSpacing = 2
        let font = NSFont.systemFont(ofSize: 13, weight: .regular)
        let piece = ns.substring(with: window).replacingOccurrences(of: "\n", with: " ")
        let base: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: settings.theme.secondary, .paragraphStyle: style,
        ]
        let out = NSMutableAttributedString(string: piece, attributes: base)
        let highlight = NSIntersectionRange(current, window)
        if highlight.length > 0 {
            let local = NSRange(location: highlight.location - window.location, length: highlight.length)
            out.addAttributes([
                .foregroundColor: settings.theme.text,
                .backgroundColor: settings.theme.accent.withAlphaComponent(0.22),
                .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            ], range: local)
        }
        if window.location > 0 { out.insert(NSAttributedString(string: "… ", attributes: base), at: 0) }
        if NSMaxRange(window) < ns.length { out.append(NSAttributedString(string: " …", attributes: base)) }
        return out
    }
}
