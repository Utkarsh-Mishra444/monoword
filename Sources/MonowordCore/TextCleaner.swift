import Foundation

/// Turns text copied from anywhere (a web page, a terminal, a PDF, Markdown) into plain prose.
///
/// Output contract, relied on by `Tokenizer`:
/// - words inside a line are separated by single spaces;
/// - "\n" marks a line break the writer meant (a short line in a tweet or a poem);
/// - "\n\n" separates blocks (paragraphs, list items, headings);
/// - no leading or trailing whitespace.
public enum TextCleaner {

    public static func clean(_ raw: String) -> String {
        var text = raw.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
        // A soft hyphen at a line end is a visible hyphenation: keep it so the halves are rejoined.
        if text.contains("\u{00AD}") {
            text = text.replacingOccurrences(of: "\u{00AD}[ \t]*\n", with: "-\n", options: .regularExpression)
        }
        text = stripTerminalEscapes(text)
        text = normalizeCharacters(text)

        let lines = text.components(separatedBy: "\n").map(classify)
        // A line that ends because the terminal (or the PDF column) ran out of room should be joined
        // with the next one; a line the writer ended on purpose keeps its break. The widest line is
        // the best estimate of where wrapping happened.
        let width = lines.filter { $0.kind == .text || $0.kind == .listItem }.map(\.visualLength).max() ?? 0

        var blocks: [String] = []
        var current = ""
        var previous: Line?

        func endBlock() {
            let trimmed = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { blocks.append(trimmed) }
            current = ""
            previous = nil
        }

        for line in lines {
            switch line.kind {
            case .blank, .fence:
                endBlock()
            case .heading:
                endBlock()
                current = line.text
                endBlock()
            case .listItem:
                endBlock()
                current = line.text
                previous = line
            case .text:
                guard let prev = previous, !current.isEmpty else {
                    current = line.text
                    previous = line
                    continue
                }
                let separator = joiner(between: prev, and: line, width: width, current: &current)
                current += separator + line.text
                previous = line
            }
        }
        endBlock()
        return blocks.joined(separator: "\n\n")
    }

    // MARK: - Lines

    enum Kind { case blank, text, listItem, heading, fence }

    struct Line {
        var text: String
        var kind: Kind
        /// Length of the line as it appeared on screen (after character normalisation, before any
        /// marker is stripped); used to tell wrapped lines from deliberate breaks.
        var visualLength: Int
    }

    static func classify(_ rawLine: String) -> Line {
        let visual = rawLine.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        var t = rawLine.trimmingCharacters(in: .whitespaces)
        let visualLength = visual.count
        if t.isEmpty { return Line(text: "", kind: .blank, visualLength: 0) }
        if t.hasPrefix("```") || t.hasPrefix("~~~") { return Line(text: "", kind: .fence, visualLength: 0) }

        // Buttons that come along when a post is selected on x.com.
        if uiLines.contains(t) { return Line(text: "", kind: .blank, visualLength: 0) }

        // Blockquotes and the "> " Claude Code puts in front of a prompt.
        while t.hasPrefix(">") {
            t.removeFirst()
            t = t.trimmingCharacters(in: .whitespaces)
        }
        if t.isEmpty { return Line(text: "", kind: .blank, visualLength: 0) }

        // Horizontal rules, Setext underlines and table separator rows carry no words.
        if t.range(of: #"^[-=*_~|:+\s]{3,}$"#, options: .regularExpression) != nil,
           t.contains(where: { $0 != " " }) {
            return Line(text: "", kind: .blank, visualLength: 0)
        }

        var kind = Kind.text
        if let r = t.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
            t.removeSubrange(r)
            t = t.replacingOccurrences(of: #"\s+#+\s*$"#, with: "", options: .regularExpression)
            kind = .heading
        } else if let r = t.range(of: listMarkerPattern, options: .regularExpression) {
            t.removeSubrange(r)
            if let box = t.range(of: #"^\[[ xX]\]\s+"#, options: .regularExpression) { t.removeSubrange(box) }
            kind = .listItem
        }

        t = stripInlineMarkdown(t)
        // Table rows ("| a | b |"): the pipes are layout, not words. A pipe in code stays.
        if t.hasPrefix("|") { t = t.replacingOccurrences(of: "|", with: " ") }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        if t.isEmpty { return Line(text: "", kind: .blank, visualLength: 0) }
        return Line(text: t, kind: kind, visualLength: visualLength)
    }

    static let uiLines: Set<String> = ["Show more", "Show less", "Translate post", "Translate Tweet", "Show translation"]

    /// Bullets ("- ", "* ", "• "...), numbered items ("1. ", "2) ") and "a) ".
    static let listMarkerPattern = #"^(?:[-*+•◦▪▫‣⁃●○■□➤➢→]|\d{1,3}[.)]|[a-z]\))\s+"#

    static func joiner(between prev: Line, and next: Line, width: Int, current: inout String) -> String {
        // "exam-" + "ple": a word hyphenated across a line break (PDFs, typeset text).
        if let last = current.last, last == "-",
           current.dropLast().last?.isLetter == true,
           next.text.first?.isLowercase == true {
            current.removeLast()
            return ""
        }
        let nextWord = next.text.split(separator: " ", maxSplits: 1).first.map(\.count) ?? 0
        let wrapped = width >= 30 && Double(prev.visualLength + 1 + nextWord) >= 0.8 * Double(width)
        return wrapped ? " " : "\n"
    }

    // MARK: - Characters

    static func stripTerminalEscapes(_ s: String) -> String {
        guard s.contains("\u{1B}") else { return s }
        var out = s.replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(?:\u{07}|\u{1B}\\\\)", with: "",
                                         options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
        out = out.replacingOccurrences(of: "\u{1B}[@-Z\\\\-_]", with: "", options: .regularExpression)
        return out
    }

    static func normalizeCharacters(_ s: String) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(s.unicodeScalars.count)
        for u in s.unicodeScalars {
            switch u.value {
            case 0x00AD, 0x200B, 0x200C, 0x2060, 0xFEFF, 0xFFFC, 0xE000, 0xE001:
                continue  // soft hyphen, zero-width characters (U+200D is kept: emoji use it), image
                          // placeholder, and the two private-use characters the Markdown pass uses
            case 0x2010, 0x2011:
                scalars.append("-")  // typographic hyphens, so line-end hyphenation is recognised
            case 0x09, 0x0B, 0x0C, 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000:
                scalars.append(" ")
            case 0x2028, 0x2029:
                scalars.append("\n")
            case 0x2500...0x259F,   // box drawing and block elements (terminal frames)
                 0x2800...0x28FF,   // braille spinners
                 0x23FA, 0x23BF,    // Claude Code's ⏺ and ⎿
                 0x2722, 0x2733, 0x2736, 0x273B, 0x273D:  // ✢ ✳ ✶ ✻ ✽ spinner glyphs
                scalars.append(" ")
            case 0x00...0x1F where u != "\n":
                scalars.append(" ")
            case 0x7F:
                continue
            default:
                scalars.append(u)
            }
        }
        return String(scalars)
    }

    // MARK: - Inline Markdown

    // Every span is bounded (at most 200 or 500 characters) so an unclosed marker on a long line
    // costs linear time, not quadratic: "__dirname" followed by 20,000 characters of prose took
    // 10 s with open-ended spans.
    private static let codeSpan = try! NSRegularExpression(pattern: #"(`{1,3})([^`]{1,500}?)\1"#)

    // Link targets must look like links (a scheme, or a path starting with / # .), so code such as
    // handlers[type](event) is left alone. __bold__ needs a space inside, so __init__ survives.
    private static let inlineRules: [(NSRegularExpression, String)] = {
        func rx(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        let target = #"(?:[A-Za-z][A-Za-z0-9+.-]{0,30}:|/|#|\.)"#
        return [
            (rx(#"!\[([^\]\n]{0,200})\]\("# + target + #"[^)\s]{0,500}\)"#), "$1"),        // ![alt](src)
            (rx(#"\[([^\]\n]{1,200})\]\("# + target + #"[^()\s]{0,500}(?:\([^)\s]{0,200}\)[^()\s]{0,200})?\)"#), "$1"), // [text](url)
            (rx(#"\*\*(?=\S)([^*\n]{1,200}?)(?<=\S)\*\*"#), "$1"),                       // **bold**
            (rx(#"(?<!\w)__(?=\S)(?=(?:(?!__)[^\n]){0,200}?\s)((?:(?!__)[^\n]){1,200}?)(?<=\S)__(?!\w)"#), "$1"), // __bold text__
            (rx(#"~~(?=\S)([^~\n]{1,200}?)(?<=\S)~~"#), "$1"),                              // ~~strike~~
            (rx(#"(?<![\w*])\*(?=[^\s*])([^*\n]{1,200}?)(?<=[^\s*])\*(?![\w*])"#), "$1"),   // *em*
        ]
    }()

    /// Longest line the Markdown rules run on; longer lines are left as they are.
    static let markdownLineLimit = 10_000

    static func stripInlineMarkdown(_ s: String) -> String {
        guard s.contains(where: { "*_`[~".contains($0) }) else { return s }
        let ns = s as NSString
        guard ns.length <= markdownLineLimit else { return s }
        // Code spans keep their text verbatim: park them behind placeholders (private-use characters,
        // which normalizeCharacters removes from the input) while the rules run.
        var spans: [String] = []
        var out = ""
        var last = 0
        for m in codeSpan.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            out += "\u{E000}\(spans.count)\u{E001}"
            spans.append(ns.substring(with: m.range(at: 2)).trimmingCharacters(in: .whitespaces))
            last = NSMaxRange(m.range)
        }
        out += ns.substring(from: last)
        for (re, template) in inlineRules {
            out = re.stringByReplacingMatches(in: out, range: NSRange(location: 0, length: (out as NSString).length),
                                              withTemplate: template)
        }
        out = out.replacingOccurrences(of: "`", with: "")
        guard !spans.isEmpty else { return out }
        // Put the spans back in one pass.
        var result = String.UnicodeScalarView()
        var index: Int?
        for u in out.unicodeScalars {
            if u == "\u{E000}" {
                index = 0
            } else if u == "\u{E001}", let i = index {
                if i < spans.count { result.append(contentsOf: spans[i].unicodeScalars) }
                index = nil
            } else if let i = index, let digit = u.properties.numericType != nil ? Int(String(u)) : nil {
                index = i * 10 + digit
            } else {
                result.append(u)
            }
        }
        return String(result)
    }
}
