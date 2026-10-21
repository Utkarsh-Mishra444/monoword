import Foundation

/// How long the reader should linger after a token, from punctuation and layout.
public enum Pause: Int, Comparable, Sendable {
    case none = 0, clause, line, sentence, paragraph
    public static func < (a: Pause, b: Pause) -> Bool { a.rawValue < b.rawValue }
}

public struct Token: Equatable, Sendable {
    /// What is flashed on screen.
    public var text: String
    /// UTF-16 range of the source word in `Document.text` (pieces of a split word share it).
    public var range: NSRange
    public var pause: Pause
    public var sentence: Int
    public var paragraph: Int
    public var isLink: Bool
    /// True for the second and later pieces of a long word that was split for display.
    public var isContinuation: Bool
    /// True when another piece of the same word follows this one.
    public var continues: Bool
}

public struct Document: Sendable {
    /// The cleaned text the token ranges point into.
    public let text: String
    public let tokens: [Token]
    /// Token index where each sentence (or deliberate line) starts; `sentenceStarts[s]` for sentence s.
    public let sentenceStarts: [Int]

    /// Words in the source, counting a split word once.
    public var wordCount: Int { tokens.reduce(0) { $0 + ($1.isContinuation ? 0 : 1) } }
    public var isEmpty: Bool { tokens.isEmpty }

    public init(raw: String, options: TokenizerOptions = .init()) {
        self = Tokenizer.tokenize(TextCleaner.clean(raw), options: options)
    }

    init(text: String, tokens: [Token], sentenceStarts: [Int]) {
        self.text = text
        self.tokens = tokens
        self.sentenceStarts = sentenceStarts
    }
}

public struct TokenizerOptions: Equatable, Sendable {
    /// Show "x.com" for a link instead of the whole URL.
    public var shortenLinks: Bool
    /// Words longer than this are split into hyphenated pieces.
    public var maxPieceLength: Int
    public init(shortenLinks: Bool = true, maxPieceLength: Int = 13) {
        self.shortenLinks = shortenLinks
        self.maxPieceLength = max(6, maxPieceLength)
    }
}

public enum Tokenizer {

    public static func tokenize(_ text: String, options: TokenizerOptions = .init()) -> Document {
        let chars = Array(text)
        var offsets = [Int](repeating: 0, count: chars.count + 1)
        for (i, ch) in chars.enumerated() { offsets[i + 1] = offsets[i] + ch.utf16.count }

        // Pass 1: raw words with the break that follows each.
        struct RawWord { var text: String; var range: NSRange; var after: Pause }
        var words: [RawWord] = []
        var i = 0
        while i < chars.count {
            while i < chars.count, chars[i].isWhitespace { i += 1 }
            guard i < chars.count else { break }
            let start = i
            while i < chars.count, !chars[i].isWhitespace { i += 1 }
            let end = i
            var newlines = 0
            while i < chars.count, chars[i].isWhitespace {
                if chars[i].isNewline { newlines += 1 }
                i += 1
            }
            let after: Pause = i >= chars.count ? .paragraph : newlines >= 2 ? .paragraph : newlines == 1 ? .line : .none
            words.append(RawWord(text: String(chars[start..<end]),
                                 range: NSRange(location: offsets[start], length: offsets[end] - offsets[start]),
                                 after: after))
        }

        // Pass 2: pieces and pauses.
        var tokens: [Token] = []
        for (w, word) in words.enumerated() {
            let nextWord = w + 1 < words.count ? words[w + 1].text : nil
            let previousWord = w > 0 ? words[w - 1].text : nil
            let pieces = split(word.text, options: options)
            if pieces.isEmpty { continue }

            // A word made only of punctuation ("—", "-", "•", "|", "/") is not shown on its own: it
            // lends its pause to the word before it on the same line. It never reaches back across a
            // line or list item (that glued "sentence ↑ / ↓:" into one flash); at a line start it is
            // dropped.
            if pieces.count == 1, !pieces[0].text.contains(where: isContent) {
                if var last = tokens.last, last.pause < .line {
                    tokens.removeLast()
                    if pieces[0].text.count <= 2 { last.text += " " + pieces[0].text }
                    last.pause = max(last.pause, punctuationPause(pieces[0].text, previous: previousWord, next: nextWord), word.after, .clause)
                    tokens.append(last)
                }
                continue
            }

            for (p, piece) in pieces.enumerated() {
                var pause: Pause = .none
                if p == pieces.count - 1 {
                    pause = max(punctuationPause(piece.text, previous: previousWord, next: nextWord), word.after)
                } else if piece.splitAtDash {
                    pause = .clause
                }
                tokens.append(Token(text: piece.text, range: word.range, pause: pause,
                                    sentence: 0, paragraph: 0, isLink: piece.isLink,
                                    isContinuation: piece.isContinuation, continues: piece.continues))
            }
        }

        // Pass 3: sentence (or deliberate line) and paragraph numbering.
        var sentenceStarts: [Int] = []
        if !tokens.isEmpty {
            tokens[tokens.count - 1].pause = .paragraph
            var sentence = 0, paragraph = 0
            sentenceStarts = [0]
            for k in tokens.indices {
                tokens[k].sentence = sentence
                tokens[k].paragraph = paragraph
                if tokens[k].pause >= .line, k + 1 < tokens.count {
                    sentence += 1
                    sentenceStarts.append(k + 1)
                }
                if tokens[k].pause == .paragraph { paragraph += 1 }
            }
        }
        return Document(text: text, tokens: tokens, sentenceStarts: sentenceStarts)
    }

    // MARK: - Splitting one whitespace-delimited word

    struct Piece {
        var text: String
        var isLink = false
        var isContinuation = false
        var continues = false
        var splitAtDash = false
    }

    static func split(_ word: String, options: TokenizerOptions) -> [Piece] {
        if let link = linkPiece(word, shorten: options.shortenLinks) {
            if options.shortenLinks { return [link] }
            let parts = splitLong(link.text, max: options.maxPieceLength)
            return parts.enumerated().map { k, text in
                Piece(text: text, isLink: true, isContinuation: k > 0, continues: k < parts.count - 1)
            }
        }
        var out: [Piece] = []
        let dashParts = splitAtDashes(word)
        for (d, part) in dashParts.enumerated() {
            let long = splitLong(part, max: options.maxPieceLength)
            for (k, text) in long.enumerated() {
                var piece = Piece(text: text)
                piece.isContinuation = k > 0
                piece.continues = k < long.count - 1
                piece.splitAtDash = k == long.count - 1 && d < dashParts.count - 1
                out.append(piece)
            }
        }
        return out
    }

    /// "word—word" -> ["word—", "word"]; "this...that" -> ["this...", "that"].
    static func splitAtDashes(_ word: String) -> [String] {
        let chars = Array(word)
        guard chars.count > 2 else { return [word] }
        var parts: [String] = []
        var start = 0
        var i = 0
        while i < chars.count {
            var sepLength = 0
            if chars[i] == "—" || chars[i] == "–" || chars[i] == "…" {
                sepLength = 1
            } else if chars[i] == "-", i + 1 < chars.count, chars[i + 1] == "-" {
                sepLength = 2
            } else if chars[i] == ".", i + 2 < chars.count, chars[i + 1] == ".", chars[i + 2] == "." {
                sepLength = 3
            }
            if sepLength > 0 {
                let end = i + sepLength
                let leftHasContent = chars[start..<i].contains(where: isContent)
                let rightHasContent = end < chars.count && chars[end...].contains(where: isContent)
                if leftHasContent && rightHasContent {
                    parts.append(String(chars[start..<end]))
                    start = end
                }
                i = end
            } else {
                i += 1
            }
        }
        parts.append(String(chars[start...]))
        return parts.filter { !$0.isEmpty }
    }

    private static let leadingWrappers = Set("([{<\"'“‘«")
    private static let trailingWrappers = Set(")]}>\"'”’».,;:!?")

    /// A URL, with or without a scheme ("https://x.com/a", "www.x.com", "github.com/a/b…" as X shows
    /// truncated links). Shortened to its site name unless `shorten` is off.
    static func linkPiece(_ word: String, shorten: Bool) -> Piece? {
        var core = Substring(word)
        while let f = core.first, leadingWrappers.contains(f) { core = core.dropFirst() }
        var trailing = ""
        while let l = core.last, trailingWrappers.contains(l) || l == "…" {
            // Keep a closing paren that belongs to the URL, e.g. wikipedia/Foo_(bar).
            if l == ")" && core.contains("(") { break }
            trailing = String(l) + trailing
            core = core.dropLast()
        }
        let lower = core.lowercased()
        let hasScheme = lower.hasPrefix("http://") || lower.hasPrefix("https://")
        let bare = !hasScheme && (lower.hasPrefix("www.") || isBareURL(lower))
        guard hasScheme || bare else { return nil }
        let withScheme = hasScheme ? String(core) : "https://" + core
        guard var host = URLComponents(string: withScheme)?.host ?? URL(string: withScheme)?.host,
              host.contains(".") else { return nil }
        // Keep the trailing sentence punctuation so the pause survives (a truncation "…" is not one).
        let tail = trailing.filter { ".,;:!?".contains($0) }
        guard shorten else { return Piece(text: String(core) + tail, isLink: true) }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return Piece(text: host + tail, isLink: true)
    }

    /// "github.com/a/b" yes; "Node.js/Deno" or "README.md/CHANGELOG.md" no: the domain must end in a
    /// known top-level domain, not a file extension.
    static func isBareURL(_ lower: String) -> Bool {
        guard let slash = lower.firstIndex(of: "/") else { return false }
        let host = lower[..<slash]
        guard host.range(of: #"^[a-z0-9-]+(\.[a-z0-9-]+)*\.[a-z]{2,}$"#, options: .regularExpression) != nil,
              let tld = host.split(separator: ".").last else { return false }
        return commonTLDs.contains(String(tld))
    }

    private static let commonTLDs: Set<String> = [
        "com", "org", "net", "io", "ai", "dev", "app", "co", "me", "gov", "edu", "info", "xyz", "tech",
        "blog", "news", "page", "site", "wiki", "link", "fm", "tv", "gg", "ly", "so", "to", "sh", "is",
        "im", "cc", "gl", "us", "uk", "ca", "au", "de", "fr", "in", "jp", "nl", "se", "ch", "es", "it",
        "eu", "be", "at", "dk", "fi", "no", "pl", "br", "cn", "kr", "ru", "nz", "ie", "il", "sg", "hk",
    ]

    /// Splits a word longer than `max` characters into pieces of at most `max`, preferring
    /// hyphens, slashes, underscores, dots, camelCase humps, then dictionary hyphenation.
    static func splitLong(_ word: String, max: Int) -> [String] {
        let chars = Array(word)
        guard chars.count > max else { return [word] }
        var pieces: [String] = []
        var start = 0
        while chars.count - start > max {
            let limit = start + max - 1   // leave room for an added hyphen
            var cut = -1
            var addHyphen = true
            // Natural boundaries: after - / _ . (no hyphen added, so the piece may use all `max`
            // characters), or a camelCase hump or letter/digit change (hyphen added).
            var j = min(start + max, chars.count - 1)
            while j > start + 2 {
                let prev = chars[j - 1], cur = chars[j]
                if "-/_.".contains(prev) { cut = j; addHyphen = false; break }
                if j <= limit {
                    if prev.isLowercase && cur.isUppercase { cut = j; break }
                    if prev.isLetter && cur.isNumber || prev.isNumber && cur.isLetter { cut = j; break }
                }
                j -= 1
            }
            if cut < 0 {
                cut = hyphenationPoint(chars, start: start, limit: limit) ?? -1
            }
            if cut < 0 {
                // Even split: avoids a long piece followed by a two-letter stub.
                let remaining = chars.count - start
                let parts = Int((Double(remaining) / Double(max - 1)).rounded(.up))
                cut = start + Int((Double(remaining) / Double(parts)).rounded(.up))
            }
            let text = String(chars[start..<cut])
            pieces.append(addHyphen && !text.hasSuffix("-") ? text + "-" : text)
            start = cut
        }
        pieces.append(String(chars[start...]))
        return pieces
    }

    private static let hyphenationLocale = Locale(identifier: "en_US") as CFLocale

    static func hyphenationPoint(_ chars: [Character], start: Int, limit: Int) -> Int? {
        let segment = String(chars[start...])
        guard segment.allSatisfy({ $0.isLetter }),
              CFStringIsHyphenationAvailableForLocale(hyphenationLocale) else { return nil }
        let cf = segment as CFString
        let length = CFStringGetLength(cf)
        var before = String(chars[start..<limit]).utf16.count
        while before > 3 {
            var hyphenChar: UTF32Char = 0
            let loc = CFStringGetHyphenationLocationBeforeIndex(
                cf, before, CFRange(location: 0, length: length), 0, hyphenationLocale, &hyphenChar)
            guard loc != kCFNotFound, loc >= 3 else { return nil }
            // Do not leave a stub shorter than 3 letters on the right.
            if length - loc >= 3 {
                guard let prefix = String(segment.utf16.prefix(loc)) else { return nil }
                return start + prefix.count
            }
            before = min(loc, before - 1)
        }
        return nil
    }

    // MARK: - Punctuation

    private static let closers = Set(")]}\"'”’»*_")
    private static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st", "vs", "e.g", "i.e", "cf", "approx",
        "al", "inc", "ltd", "jan", "feb", "mar", "apr", "jun", "jul", "aug", "sep", "sept", "oct",
        "nov", "dec",
    ]
    /// Abbreviations only when a number follows ("fig. 3", "no. 5"); otherwise ordinary words.
    private static let numberAbbreviations: Set<String> = [
        "no", "fig", "figs", "vol", "ch", "pp", "p", "eq", "eqs", "ref", "refs", "sec", "art", "pt",
    ]

    static func punctuationPause(_ word: String, previous: String? = nil, next: String?) -> Pause {
        var chars = Array(word)
        while let last = chars.last, closers.contains(last), chars.count > 1 { chars.removeLast() }
        guard let last = chars.last else { return .none }
        let nextIsCapital = next?.first(where: { $0.isLetter })?.isUppercase ?? true
        // "waited… and" trails off mid-sentence; "waited… Then" ends one.
        let ellipsis: Pause = nextIsCapital ? .sentence : .clause
        switch last {
        case "!", "?", "‽", "。", "！", "？":
            return .sentence
        case "…":
            return ellipsis
        case ".":
            if chars.count >= 3, chars[chars.count - 2] == ".", chars[chars.count - 3] == "." { return ellipsis }
            let original = String(chars.dropLast()).trimmingCharacters(in: CharacterSet(charactersIn: "([{\"'“‘«"))
            let core = original.lowercased()
            let nextIsNumber = next?.first(where: { !"([#".contains($0) })?.isNumber ?? false
            if abbreviations.contains(core) { return .none }
            if numberAbbreviations.contains(core) { return nextIsNumber ? .none : .sentence }
            if core == "etc" { return nextIsCapital ? .sentence : .clause }
            // An initial inside a name: "J. K. Rowling", "George W. Bush". Not "an A. Then" or
            // "vitamin C. It", where the word before is lowercase.
            let nextIsInitial = next?.range(of: #"^[A-Z]\.$"#, options: .regularExpression) != nil
            let previousIsCapitalised = previous.map { $0.first(where: { $0.isLetter })?.isUppercase ?? false } ?? true
            if original.count == 1, original.first?.isUppercase == true, nextIsCapital,
               nextIsInitial || previousIsCapitalised {
                return .none
            }
            // Initialisms such as U.S. or a.m.: a sentence end only when a capital follows.
            if core.range(of: #"^([a-z]\.)+[a-z]$"#, options: .regularExpression) != nil {
                return nextIsCapital ? .sentence : .none
            }
            return .sentence
        case ",", ";", ":", "—", "–", "、", "，", "；", "：":
            return .clause
        default:
            return .none
        }
    }

    // MARK: - Characters

    static func isContent(_ ch: Character) -> Bool {
        if ch.isLetter || ch.isNumber { return true }
        guard let u = ch.unicodeScalars.first else { return false }
        if u.properties.isEmojiPresentation || (u.properties.isEmoji && u.value > 0x238C) { return true }
        // Arrows, ⌘ ⌥ ⌃, maths and currency signs carry meaning: they are words of their own
        // (but not the layout characters | ~ ^, which Unicode also files as maths symbols).
        if "|~^¦".contains(ch) { return false }
        switch u.properties.generalCategory {
        case .mathSymbol, .otherSymbol, .currencySymbol: return true
        default: return "&@#%".contains(ch)
        }
    }
}
