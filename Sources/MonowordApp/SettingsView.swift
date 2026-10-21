import AppKit
import SwiftUI

final class SettingsHostingController: NSHostingController<SettingsView> {
    init() { super.init(rootView: SettingsView(settings: Settings.shared)) }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }
}

struct SettingsView: View {
    @ObservedObject var settings: Settings
    @State private var trusted = SelectionGrabber.isTrusted
    @State private var loginItem = AppDelegate.launchesAtLogin
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Form {
            Section("Reading") {
                HStack {
                    Text("Speed")
                    Slider(value: Binding(get: { Double(settings.wpm) }, set: { settings.wpm = Int($0) }),
                           in: Double(Settings.wpmRange.lowerBound)...Double(Settings.wpmRange.upperBound), step: 25)
                    Text("\(settings.wpm) wpm").monospacedDigit().frame(width: 74, alignment: .trailing)
                }
                Picker("Words per flash", selection: $settings.chunkSize) {
                    Text("Auto").tag(0); Text("1").tag(1); Text("2").tag(2); Text("3").tag(3)
                }
                .pickerStyle(.segmented)
                if settings.chunkSize == 0 {
                    Text("Auto: two tiny words like it, a, is, to share a flash (\"it is\", \"of the\", \"in a\"). Every word that carries meaning is shown alone.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.realSpeed) {
                    Text("Speed is real reading speed")
                    Text(settings.realSpeed
                         ? "\(settings.wpm) wpm means \(settings.wpm) words a minute, pauses included: the words run faster to make room for them."
                         : "\(settings.wpm) wpm is the speed of the words alone; pauses at punctuation add time on top.")
                }
                HStack {
                    Text("Pause at punctuation")
                    Slider(value: $settings.punctuationPause, in: 0...2)
                    Text(pauseLabel).frame(width: 74, alignment: .trailing).foregroundStyle(.secondary)
                }
                Toggle(isOn: $settings.adaptivePacing) {
                    Text("Adaptive pacing")
                    Text("Rare and long words, numbers and links get a little more time, common short words a little less. This moves time between words; it never changes your speed.")
                }
                if !settings.adaptivePacing {
                    Toggle("Extra time for long words, numbers and links", isOn: $settings.lengthPause)
                }
                Toggle("Ease in for the first few words", isOn: $settings.rampUp)
                Toggle("Start reading right away", isOn: $settings.autoStart)
                Toggle("Close when finished", isOn: $settings.closeWhenDone)
                Toggle("Show links as their site name", isOn: $settings.shortenLinks)
            }
            Section("Look") {
                Picker("Theme", selection: $settings.theme) {
                    ForEach(Theme.allCases) { Text($0.title).tag($0) }
                }
                Picker("Font", selection: $settings.font) {
                    ForEach(FontChoice.allCases) { Text($0.title).tag($0) }
                }
                HStack {
                    Text("Size")
                    Slider(value: $settings.fontSize, in: 24...96, step: 2)
                    Text("\(Int(settings.fontSize)) pt").monospacedDigit().frame(width: 74, alignment: .trailing)
                }
                #if LOCAL_EXTENSIONS
                LocalLookSettings()
                #endif
                Toggle("Guide lines", isOn: $settings.showGuides)
                Toggle("Dim the screen while reading", isOn: $settings.dimScreen)
            }
            Section("Shortcuts (work in every app)") {
                Toggle("Double-tap right ⌘ to read the selection", isOn: $settings.doubleTapRightCommand)
                LabeledContent("Read selection") { ShortcutField(shortcut: $settings.readShortcut) }
                LabeledContent("Read clipboard") { ShortcutField(shortcut: $settings.clipboardShortcut) }
                Text("Also in any app: right-click selected text › Services › Read with Monoword.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("System") {
                Toggle("Open at login", isOn: Binding(get: { loginItem }, set: {
                    AppDelegate.launchesAtLogin = $0
                    loginItem = AppDelegate.launchesAtLogin
                }))
                HStack {
                    if trusted {
                        Label("Accessibility allowed: selected text is read directly", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    } else {
                        Label("Accessibility is off: only the clipboard can be read", systemImage: "exclamationmark.circle")
                        Spacer()
                        Button("Allow…") { SelectionGrabber.requestAccess() }
                    }
                }
            }
            Section {
                Text("Monoword \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev") (\(Bundle.main.object(forInfoDictionaryKey: "SRBuildCommit") as? String ?? "dev"))")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Word frequencies: OpenSubtitles 2018 via hermitdave/FrequencyWords, CC BY-SA 4.0.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 520, height: 640)
        .onReceive(timer) { _ in
            trusted = SelectionGrabber.isTrusted
            loginItem = AppDelegate.launchesAtLogin
        }
    }

    private var pauseLabel: String {
        switch settings.punctuationPause {
        case ..<0.15: return "off"
        case ..<0.75: return "short"
        case ..<1.35: return "normal"
        default: return "long"
        }
    }
}

/// Click, then type the new shortcut. Esc cancels, Delete clears it.
struct ShortcutField: NSViewRepresentable {
    @Binding var shortcut: Shortcut?

    func makeNSView(context: Context) -> RecorderButton {
        let b = RecorderButton()
        b.onChange = { shortcut = $0 }
        b.shortcut = shortcut
        return b
    }

    func updateNSView(_ view: RecorderButton, context: Context) {
        view.onChange = { shortcut = $0 }
        if !view.isRecording { view.shortcut = shortcut }
    }
}

final class RecorderButton: NSButton {
    var onChange: ((Shortcut?) -> Void)?
    var shortcut: Shortcut? { didSet { refresh() } }
    private(set) var isRecording = false

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 24))
        bezelStyle = .rounded
        setButtonType(.momentaryPushIn)
        target = self
        action = #selector(startRecording)
        refresh()
    }
    @available(*, unavailable) required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: super.intrinsicContentSize.height) }
    override var acceptsFirstResponder: Bool { true }

    private func refresh() {
        title = isRecording ? "Type shortcut…" : (shortcut?.displayString ?? "None")
    }

    // Leaving the window (switching apps, closing Settings) ends recording, so the global
    // shortcuts are never left switched off.
    private var windowObservers: [NSObjectProtocol] = []

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)
        windowObservers.forEach(NotificationCenter.default.removeObserver)
        windowObservers = []
        guard let newWindow else { if isRecording { stopRecording() }; return }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            windowObservers.append(NotificationCenter.default.addObserver(forName: name, object: newWindow, queue: .main) {
                [weak self] _ in
                if self?.isRecording == true { self?.stopRecording() }
            })
        }
    }

    @objc private func startRecording() {
        isRecording = true
        AppDelegate.shared?.suspendHotKeys()   // so the current combination can be typed again
        window?.makeFirstResponder(self)
        refresh()
    }

    private func stopRecording() {
        isRecording = false
        AppDelegate.shared?.resumeHotKeys()
        refresh()
    }

    override func resignFirstResponder() -> Bool {
        if isRecording { stopRecording() }
        return super.resignFirstResponder()
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard isRecording else { return super.performKeyEquivalent(with: event) }
        keyDown(with: event)
        return true
    }

    override func keyDown(with event: NSEvent) {
        guard isRecording else { super.keyDown(with: event); return }
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        switch Int(event.keyCode) {
        case 53:  // esc
            stopRecording()
        case 51, 117:  // delete, forward delete
            shortcut = nil
            onChange?(nil)
            stopRecording()
        default:
            let isFunctionKey = (122...135).contains(Int(event.keyCode)) || [96, 97, 98, 99, 100, 101, 103, 105, 106, 107, 109, 111, 113].contains(Int(event.keyCode))
            // Plain letters would fire while typing; insist on ⌘, ⌃ or ⌥ (F-keys may stand alone).
            guard isFunctionKey || flags.contains(.command) || flags.contains(.control) || flags.contains(.option) else {
                NSSound.beep()
                return
            }
            let s = Shortcut(event: event)
            shortcut = s
            onChange?(s)
            stopRecording()
        }
    }
}
