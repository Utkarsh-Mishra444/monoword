import AppKit
import ApplicationServices
import Combine
import ServiceManagement
import MonowordCore

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    static weak var shared: AppDelegate?

    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var hotKeyFailures: [String] = []
    private var settings: Settings { Settings.shared }

    private enum HotKeyID: UInt32 { case read = 1, clipboard = 2 }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppDelegate.shared = self
        if CommandLine.arguments.contains("--unregister-login-item") {
            try? SMAppService.mainApp.unregister()
            print("login item status after unregister: \(SMAppService.mainApp.status.rawValue)")
            exit(0)
        }
        if CommandLine.arguments.contains("--selftest-live") {
            SelfTest.runLive()
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--selftest") {
            let out = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : NSTemporaryDirectory()
            SelfTest.run(outputDirectory: URL(fileURLWithPath: out))
            return
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render") {
            RenderMode.run(arguments: Array(CommandLine.arguments[(i + 1)...]))
            return
        }
        Self.loadFrequencyTable()
        setUpStatusItem()
        registerHotKeys()
        NSApp.servicesProvider = self
        NSUpdateDynamicServices()
        settings.$readShortcut.combineLatest(settings.$clipboardShortcut)
            .dropFirst()
            .sink { [weak self] _ in DispatchQueue.main.async { self?.registerHotKeys() } }
            .store(in: &cancellables)
        ModifierTapMonitor.shared.onDoubleTap = { [weak self] in self?.readSelection() }
        ModifierTapMonitor.shared.setEnabled(settings.doubleTapRightCommand)
        settings.$doubleTapRightCommand
            .dropFirst()
            .sink { on in DispatchQueue.main.async { ModifierTapMonitor.shared.setEnabled(on) } }
            .store(in: &cancellables)
        enableLoginItemOnFirstRun()
        // Without Accessibility neither the selection nor the right-⌘ double tap can be read: ask
        // at launch (macOS shows its own prompt and adds Monoword to the Accessibility list).
        if !SelectionGrabber.isTrusted {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        Log.app.notice("launched \(Bundle.main.object(forInfoDictionaryKey: "SRBuildCommit") as? String ?? "dev", privacy: .public), trusted=\(SelectionGrabber.isTrusted)")
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls { handle(url) }
    }

    /// Word frequencies for adaptive pacing (Resources/word-frequency-en.txt), parsed off the main
    /// thread. A reader opened before it is ready paces without frequencies.
    static func loadFrequencyTable() {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let url = frequencyListURL, let text = try? String(contentsOf: url, encoding: .utf8) else {
                Log.app.error("word frequency list not found")
                return
            }
            let table = FrequencyTable(listText: text)
            DispatchQueue.main.async {
                ReaderController.frequency = table
                Log.app.notice("word frequencies loaded: \(table.count) words")
            }
        }
    }

    /// The bundled list, or the repository copy when running a bare development build.
    static var frequencyListURL: URL? {
        if let url = Bundle.main.url(forResource: "word-frequency-en", withExtension: "txt") { return url }
        #if DEBUG
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Resources/word-frequency-en.txt")
        return FileManager.default.fileExists(atPath: repo.path) ? repo : nil
        #else
        return nil
        #endif
    }

    // MARK: - Actions

    @objc func readSelection() {
        let reader = ReaderController.shared
        let wasVisible = reader.isVisible
        if wasVisible { reader.close() }
        // Let focus settle back on his app (the reader may have had it) before asking it.
        DispatchQueue.main.asyncAfter(deadline: .now() + (wasVisible ? 0.08 : 0.01)) {
            SelectionGrabber.grab { result in
                self.present(result.text, source: result.source, limited: result.limited)
            }
        }
    }

    @objc func readClipboard() {
        let text = SelectionGrabber.clipboardText(.general) ?? ""
        present(text, source: .clipboard, limited: false)
    }

    @objc func resumeLast() {
        guard let text = settings.lastText else { return }
        ReaderController.shared.open(text: text, source: .resume, startIndex: settings.lastIndex)
    }

    @objc func showGuide() {
        let keys = [settings.doubleTapRightCommand ? "double-tap the right Command key" : nil,
                    settings.readShortcut?.displayString].compactMap { $0 }
        ReaderController.shared.open(text: Self.guideText(read: keys.isEmpty ? nil : keys.joined(separator: " or press "),
                                                           clipboard: settings.clipboardShortcut?.displayString),
                                     source: .sample)
    }

    @objc func allowAccessibility() {
        SelectionGrabber.requestAccess()
    }

    @objc func setSpeed(_ sender: NSMenuItem) {
        settings.wpm = sender.tag
    }

    @objc func setChunk(_ sender: NSMenuItem) {
        settings.chunkSize = sender.tag
    }

    @objc func openSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                                  styleMask: [.titled, .closable], backing: .buffered, defer: false)
            window.title = "Monoword Settings"
            window.isReleasedWhenClosed = false
            window.contentViewController = SettingsHostingController()
            window.center()
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func present(_ text: String, source: TextSource, limited: Bool) {
        let reader = ReaderController.shared
        if text.contains(where: { !$0.isWhitespace }) {
            reader.open(text: text, source: source, limited: limited)
            return
        }
        let key = settings.readShortcut?.displayString ?? "the shortcut"
        if limited {
            reader.openMessage("Nothing on the clipboard",
                               detail: "Copy some text (⌘C) and press \(key). Allow Accessibility and \(key) reads your selection directly.",
                               limited: true)
        } else {
            reader.openMessage("Nothing selected", detail: "Select some text in any app, then press \(key).", limited: false)
        }
    }

    private func handle(_ url: URL) {
        guard url.scheme == "monoword" else { return }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        switch url.host {
        case "read":
            if let text = items.first(where: { $0.name == "text" })?.value {
                ReaderController.shared.open(text: text, source: .url)
            } else if let path = items.first(where: { $0.name == "file" })?.value,
                      let text = try? String(contentsOfFile: (path as NSString).expandingTildeInPath, encoding: .utf8) {
                ReaderController.shared.open(text: text, source: .url)
            }
        case "selection": readSelection()
        case "clipboard": readClipboard()
        case "resume": resumeLast()
        case "settings": openSettings()
        default: break
        }
    }

    // MARK: - Services menu ("Read with Monoword" in any app's right-click > Services)

    @objc func readWithMonoword(_ pasteboard: NSPasteboard, userData: String?,
                                error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        guard let text = SelectionGrabber.clipboardText(pasteboard), !text.isEmpty else {
            error.pointee = "No text was selected." as NSString
            return
        }
        ReaderController.shared.open(text: text, source: .service)
    }

    // MARK: - Hotkeys

    func registerHotKeys() {
        hotKeyFailures = []
        if !HotKeyCenter.shared.register(id: HotKeyID.read.rawValue, shortcut: settings.readShortcut,
                                         action: { [weak self] in self?.readSelection() }) {
            hotKeyFailures.append(settings.readShortcut?.displayString ?? "")
        }
        if !HotKeyCenter.shared.register(id: HotKeyID.clipboard.rawValue, shortcut: settings.clipboardShortcut,
                                         action: { [weak self] in self?.readClipboard() }) {
            hotKeyFailures.append(settings.clipboardShortcut?.displayString ?? "")
        }
    }

    func suspendHotKeys() { HotKeyCenter.shared.unregisterAll() }
    func resumeHotKeys() { registerHotKeys() }

    var hotKeyProblems: [String] { hotKeyFailures }

    // MARK: - Login item

    private func enableLoginItemOnFirstRun() {
        guard !settings.didOfferLoginItem else { return }
        // Only for the installed copy, never a build run from the project folder.
        guard Bundle.main.bundlePath.contains("/Applications/") else { return }
        settings.didOfferLoginItem = true
        try? SMAppService.mainApp.register()
    }

    static var launchesAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            if newValue { try? SMAppService.mainApp.register() } else { try? SMAppService.mainApp.unregister() }
        }
    }

    // MARK: - Menu bar

    private func setUpStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = NSImage(systemSymbolName: "hare.fill", accessibilityDescription: "Monoword")
                ?? NSImage(systemSymbolName: "bolt.fill", accessibilityDescription: "Monoword")
            image?.isTemplate = true
            button.image = image
            button.toolTip = "Monoword"
        }
        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let read = NSMenuItem(title: "Read Selection", action: #selector(readSelection), keyEquivalent: "")
        apply(settings.readShortcut, to: read)
        menu.addItem(read)
        if settings.doubleTapRightCommand {
            let tap = NSMenuItem(title: "   or double-tap right ⌘", action: nil, keyEquivalent: "")
            tap.isEnabled = false
            menu.addItem(tap)
        }
        let clip = NSMenuItem(title: "Read Clipboard", action: #selector(readClipboard), keyEquivalent: "")
        apply(settings.clipboardShortcut, to: clip)
        menu.addItem(clip)
        if settings.lastText != nil {
            let pct = Int((settings.lastProgress * 100).rounded())
            menu.addItem(NSMenuItem(title: "Resume Last (\(pct)% read)", action: #selector(resumeLast), keyEquivalent: ""))
        }
        menu.addItem(.separator())

        let speed = NSMenuItem(title: "Speed: \(settings.wpm) wpm", action: nil, keyEquivalent: "")
        let speedMenu = NSMenu()
        var presets = [200, 250, 300, 350, 400, 450, 500, 600, 700, 800, 900, 1000]
        if !presets.contains(settings.wpm) { presets.append(settings.wpm); presets.sort() }
        for wpm in presets {
            let i = NSMenuItem(title: "\(wpm) wpm", action: #selector(setSpeed(_:)), keyEquivalent: "")
            i.tag = wpm
            i.state = wpm == settings.wpm ? .on : .off
            speedMenu.addItem(i)
        }
        speedMenu.addItem(.separator())
        let tip = NSMenuItem(title: "In the reader: ↑ ↓ change speed", action: nil, keyEquivalent: "")
        tip.isEnabled = false
        speedMenu.addItem(tip)
        speed.submenu = speedMenu
        menu.addItem(speed)

        let chunk = NSMenuItem(title: "Words per Flash: \(settings.chunkSize == 0 ? "Auto" : String(settings.chunkSize))",
                               action: nil, keyEquivalent: "")
        let chunkMenu = NSMenu()
        for n in 0...3 {
            let title = n == 0 ? "Auto (group short words)" : n == 1 ? "1 word" : "\(n) words"
            let i = NSMenuItem(title: title, action: #selector(setChunk(_:)), keyEquivalent: "")
            i.tag = n
            i.state = n == settings.chunkSize ? .on : .off
            chunkMenu.addItem(i)
        }
        chunk.submenu = chunkMenu
        menu.addItem(chunk)
        menu.addItem(.separator())

        if !SelectionGrabber.isTrusted {
            menu.addItem(NSMenuItem(title: "Allow Accessibility…", action: #selector(allowAccessibility), keyEquivalent: ""))
            let note = NSMenuItem(title: "Needed to read selected text directly", action: nil, keyEquivalent: "")
            note.isEnabled = false
            menu.addItem(note)
            menu.addItem(.separator())
        }
        for failure in hotKeyFailures where !failure.isEmpty {
            let warn = NSMenuItem(title: "⚠︎ \(failure) is taken by another app: change it in Settings",
                                  action: #selector(openSettings), keyEquivalent: "")
            menu.addItem(warn)
        }
        menu.addItem(NSMenuItem(title: "How to Use", action: #selector(showGuide), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Monoword", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) { item.target = item.target ?? self }
        for item in speedMenu.items { item.target = self }
        for item in chunkMenu.items { item.target = self }
    }

    private func apply(_ shortcut: Shortcut?, to item: NSMenuItem) {
        guard let shortcut else { return }
        let (key, flags) = shortcut.menuKeyEquivalent
        if key.count == 1 {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = flags
        }
    }

    // MARK: - Guide (read with the reader itself)

    static func guideText(read: String?, clipboard: String?) -> String {
        let readKey = read ?? "your shortcut (set one in Settings)"
        let clipLine = clipboard.map { "\($0) reads whatever is on the clipboard. " } ?? ""
        return """
    Welcome to Monoword. You are reading this one word at a time, and your eyes are not moving: \
    every word appears in the same spot, so all you do is look.

    Select text in any app, a tweet in the browser, an answer in Claude Code, a PDF, and press \
    \(readKey). The words appear right here.

    Press space to pause. While paused you see the sentence around the word, so you never lose your place. \
    The left arrow jumps back a sentence, the right arrow skips ahead one.

    The up and down arrows change the speed by twenty five words a minute; hold shift for a hundred. \
    The speed is real: at four hundred, four hundred words take one minute. Start there and push \
    higher once it feels easy.

    Press A to pair tiny words like of the, or one, two or three for that many words at a time. \
    Press escape to close.

    \(clipLine)You can also right-click selected text and choose Services, then Read with Monoword. \
    That is everything. Enjoy the speed.
    """
    }
}
