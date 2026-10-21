import AppKit
import Carbon.HIToolbox
import Combine
import MonowordCore

/// A global keyboard shortcut in Carbon terms (what RegisterEventHotKey takes).
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt32   // cmdKey | optionKey | controlKey | shiftKey

    static let defaultRead = Shortcut(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(controlKey | optionKey))
    static let defaultClipboard = Shortcut(keyCode: UInt32(kVK_ANSI_V), modifiers: UInt32(controlKey | optionKey))

    var displayString: String {
        var s = ""
        if modifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { s += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { s += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { s += "⌘" }
        return s + KeyNames.name(for: keyCode)
    }

    init(keyCode: UInt32, modifiers: UInt32) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    init(event: NSEvent) {
        keyCode = UInt32(event.keyCode)
        let f = event.modifierFlags
        var m: UInt32 = 0
        if f.contains(.command) { m |= UInt32(cmdKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        modifiers = m
    }

    /// Key equivalent for an NSMenuItem showing this shortcut.
    var menuKeyEquivalent: (String, NSEvent.ModifierFlags) {
        var flags: NSEvent.ModifierFlags = []
        if modifiers & UInt32(controlKey) != 0 { flags.insert(.control) }
        if modifiers & UInt32(optionKey) != 0 { flags.insert(.option) }
        if modifiers & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if modifiers & UInt32(cmdKey) != 0 { flags.insert(.command) }
        return (KeyNames.name(for: keyCode).lowercased(), flags)
    }
}

enum Theme: String, CaseIterable, Identifiable {
    case dark, light, sepia
    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var background: NSColor {
        switch self {
        case .dark: return NSColor(srgbRed: 0.075, green: 0.075, blue: 0.085, alpha: 0.97)
        case .light: return NSColor(srgbRed: 0.985, green: 0.985, blue: 0.975, alpha: 0.98)
        case .sepia: return NSColor(srgbRed: 0.957, green: 0.925, blue: 0.847, alpha: 0.98)
        }
    }
    var text: NSColor {
        switch self {
        case .dark: return NSColor(white: 0.95, alpha: 1)
        case .light: return NSColor(srgbRed: 0.11, green: 0.11, blue: 0.12, alpha: 1)
        case .sepia: return NSColor(srgbRed: 0.23, green: 0.18, blue: 0.16, alpha: 1)
        }
    }
    var secondary: NSColor {
        switch self {
        case .dark: return NSColor(white: 0.56, alpha: 1)
        case .light: return NSColor(white: 0.45, alpha: 1)
        case .sepia: return NSColor(srgbRed: 0.48, green: 0.40, blue: 0.33, alpha: 1)
        }
    }
    var accent: NSColor {
        switch self {
        case .dark: return NSColor(srgbRed: 1.0, green: 0.36, blue: 0.31, alpha: 1)
        case .light: return NSColor(srgbRed: 0.88, green: 0.21, blue: 0.17, alpha: 1)
        case .sepia: return NSColor(srgbRed: 0.75, green: 0.22, blue: 0.17, alpha: 1)
        }
    }
    var guide: NSColor {
        switch self {
        case .dark: return NSColor(white: 1, alpha: 0.13)
        case .light: return NSColor(white: 0, alpha: 0.13)
        case .sepia: return NSColor(srgbRed: 0.35, green: 0.25, blue: 0.15, alpha: 0.18)
        }
    }
    var border: NSColor {
        switch self {
        case .dark: return NSColor(white: 1, alpha: 0.09)
        case .light, .sepia: return NSColor(white: 0, alpha: 0.08)
        }
    }
}

enum FontChoice: String, CaseIterable, Identifiable {
    case system, serif, rounded, mono
    var id: String { rawValue }
    var title: String {
        switch self {
        case .system: return "San Francisco"
        case .serif: return "New York (serif)"
        case .rounded: return "Rounded"
        case .mono: return "Monospaced"
        }
    }

    func font(size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .medium)
        let design: NSFontDescriptor.SystemDesign
        switch self {
        case .system: return base
        case .serif: design = .serif
        case .rounded: design = .rounded
        case .mono: return NSFont.monospacedSystemFont(ofSize: size, weight: .medium)
        }
        guard let d = base.fontDescriptor.withDesign(design) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }
}

/// Every preference, persisted in UserDefaults. `shared` can be swapped for an isolated suite
/// (the self-test does this, so it never touches the real preferences).
final class Settings: ObservableObject {
    static var shared = Settings(defaults: .standard)

    let defaults: UserDefaults

    @Published var wpm: Int { didSet { defaults.set(wpm, forKey: "wpm") } }
    @Published var chunkSize: Int { didSet { defaults.set(chunkSize, forKey: "chunkSize") } }
    @Published var punctuationPause: Double { didSet { defaults.set(punctuationPause, forKey: "punctuationPause") } }
    @Published var lengthPause: Bool { didSet { defaults.set(lengthPause, forKey: "lengthPause") } }
    @Published var rampUp: Bool { didSet { defaults.set(rampUp, forKey: "rampUp") } }
    @Published var adaptivePacing: Bool { didSet { defaults.set(adaptivePacing, forKey: "adaptivePacing") } }
    @Published var realSpeed: Bool { didSet { defaults.set(realSpeed, forKey: "realSpeed") } }
    @Published var autoStart: Bool { didSet { defaults.set(autoStart, forKey: "autoStart") } }
    @Published var closeWhenDone: Bool { didSet { defaults.set(closeWhenDone, forKey: "closeWhenDone") } }
    @Published var shortenLinks: Bool { didSet { defaults.set(shortenLinks, forKey: "shortenLinks") } }
    @Published var theme: Theme { didSet { defaults.set(theme.rawValue, forKey: "theme") } }
    @Published var font: FontChoice { didSet { defaults.set(font.rawValue, forKey: "font") } }
    @Published var fontSize: Double { didSet { defaults.set(fontSize, forKey: "fontSize") } }
    @Published var showGuides: Bool { didSet { defaults.set(showGuides, forKey: "showGuides") } }
    @Published var dimScreen: Bool { didSet { defaults.set(dimScreen, forKey: "dimScreen") } }
    @Published var readShortcut: Shortcut? { didSet { save(readShortcut, "readShortcut") } }
    @Published var clipboardShortcut: Shortcut? { didSet { save(clipboardShortcut, "clipboardShortcut") } }
    @Published var doubleTapRightCommand: Bool { didSet { defaults.set(doubleTapRightCommand, forKey: "doubleTapRightCommand") } }

    static let wpmRange = 100...1500

    init(defaults: UserDefaults) {
        self.defaults = defaults
        defaults.register(defaults: [
            "wpm": 400, "chunkSize": 0, "punctuationPause": 1.0, "lengthPause": true, "rampUp": true,
            "adaptivePacing": true, "realSpeed": true,
            "autoStart": true, "closeWhenDone": true, "shortenLinks": true, "theme": Theme.dark.rawValue,
            "font": FontChoice.system.rawValue, "fontSize": 46.0, "showGuides": true,
            "dimScreen": false, "doubleTapRightCommand": true,
        ])
        wpm = min(Self.wpmRange.upperBound, max(Self.wpmRange.lowerBound, defaults.integer(forKey: "wpm")))
        chunkSize = min(3, max(0, defaults.integer(forKey: "chunkSize")))   // 0 = auto grouping
        punctuationPause = defaults.double(forKey: "punctuationPause")
        lengthPause = defaults.bool(forKey: "lengthPause")
        rampUp = defaults.bool(forKey: "rampUp")
        adaptivePacing = defaults.bool(forKey: "adaptivePacing")
        realSpeed = defaults.bool(forKey: "realSpeed")
        autoStart = defaults.bool(forKey: "autoStart")
        closeWhenDone = defaults.bool(forKey: "closeWhenDone")
        shortenLinks = defaults.bool(forKey: "shortenLinks")
        theme = Theme(rawValue: defaults.string(forKey: "theme") ?? "") ?? .dark
        font = FontChoice(rawValue: defaults.string(forKey: "font") ?? "") ?? .system
        fontSize = min(96, max(24, defaults.double(forKey: "fontSize")))
        showGuides = defaults.bool(forKey: "showGuides")
        dimScreen = defaults.bool(forKey: "dimScreen")
        doubleTapRightCommand = defaults.bool(forKey: "doubleTapRightCommand")
        readShortcut = Self.load("readShortcut", defaults) ?? Shortcut.defaultRead
        clipboardShortcut = Self.load("clipboardShortcut", defaults) ?? Shortcut.defaultClipboard
    }

    var timing: TimingOptions {
        TimingOptions(wpm: Double(wpm), punctuationPause: punctuationPause, lengthPause: lengthPause, rampUp: rampUp,
                      adaptive: adaptivePacing, realSpeed: realSpeed)
    }

    var tokenizer: TokenizerOptions { TokenizerOptions(shortenLinks: shortenLinks) }

    func adjustWPM(by delta: Int) {
        wpm = min(Self.wpmRange.upperBound, max(Self.wpmRange.lowerBound, wpm + delta))
    }

    // A cleared shortcut is stored as an empty Data so it stays cleared (nil would mean "default").
    private func save(_ s: Shortcut?, _ key: String) {
        defaults.set(s.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }

    private static func load(_ key: String, _ defaults: UserDefaults) -> Shortcut?? {
        guard let data = defaults.data(forKey: key) else { return nil }        // never set: default
        if data.isEmpty { return .some(nil) }                                   // cleared by him
        return .some(try? JSONDecoder().decode(Shortcut.self, from: data))
    }

    // MARK: - Resume

    /// The last unfinished text and where he stopped (kept so "Resume" can pick it up).
    var lastText: String? {
        get { defaults.string(forKey: "lastText") }
        set { defaults.set(newValue.map { String($0.prefix(400_000)) }, forKey: "lastText") }
    }
    var lastIndex: Int {
        get { defaults.integer(forKey: "lastIndex") }
        set { defaults.set(newValue, forKey: "lastIndex") }
    }
    var lastProgress: Double {
        get { defaults.double(forKey: "lastProgress") }
        set { defaults.set(newValue, forKey: "lastProgress") }
    }
    var didOfferLoginItem: Bool {
        get { defaults.bool(forKey: "didOfferLoginItem") }
        set { defaults.set(newValue, forKey: "didOfferLoginItem") }
    }
}
