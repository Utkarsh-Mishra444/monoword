import Foundation

/// The reading cursor over a document: which tokens are on screen now, and the moves the keys make.
/// Time-free, so every move is unit tested; the app drives it with a timer.
public final class ReadingSession {

    public let document: Document
    /// First token of the chunk on screen.
    public private(set) var index: Int
    /// Words shown together: 1 to 3, or `Self.auto` to group ultra-short words with a neighbour.
    /// Pieces of a split word are always shown one at a time.
    public var chunkSize: Int {
        didSet { chunkSize = min(3, max(Self.auto, chunkSize)) }
    }
    /// Longest group of words, in characters, that is still flashed as one chunk.
    public var maxChunkCharacters = 22

    /// Auto grouping: two tiny function words share a flash ("it is", "of the", "in a", "to a"):
    /// both must be in `functionWords` and together at most `autoMaxCharacters` characters. Every
    /// other word, any word that carries meaning, is shown alone.
    public static let auto = 0
    public var autoMaxCharacters = 7

    /// Articles, prepositions, pronouns, auxiliaries and conjunctions of 1 to 3 letters.
    public static let functionWords: Set<String> = [
        "a", "an", "the", "to", "of", "in", "on", "at", "by", "for", "as", "is", "am", "are", "was",
        "be", "it", "its", "i", "me", "my", "we", "us", "our", "he", "him", "his", "she", "her", "you",
        "and", "or", "but", "so", "if", "do", "did", "has", "had", "can", "not", "no",
    ]

    public init(document: Document, chunkSize: Int = 1, startIndex: Int = 0) {
        self.document = document
        self.chunkSize = min(3, max(Self.auto, chunkSize))
        self.index = min(max(0, startIndex), max(0, document.tokens.count - 1))
    }

    public var tokenCount: Int { document.tokens.count }
    public var isEmpty: Bool { document.tokens.isEmpty }

    /// Tokens on screen now.
    public var currentRange: Range<Int> { chunk(at: index) }

    /// The text to flash for the current chunk.
    public var currentText: String {
        currentRange.map { document.tokens[$0].text }.joined(separator: " ")
    }

    public var isAtLastChunk: Bool { currentRange.upperBound >= tokenCount }

    /// Fraction of the document read before the words on screen, 0 to 1 (the one definition used
    /// for the progress bar, the percentage and the resume point).
    public var progress: Double {
        tokenCount == 0 ? 0 : Double(index) / Double(tokenCount)
    }

    /// The next `count` flashes from token `start`, as the reader will show them.
    public func chunks(from start: Int, count: Int) -> [Range<Int>] {
        var out: [Range<Int>] = []
        var i = start
        while out.count < count, i < tokenCount {
            let c = chunk(at: i)
            out.append(c)
            i = c.upperBound
        }
        return out
    }

    /// The chunk that starts at `start`: up to `chunkSize` tokens, ending early after any pause,
    /// at a split word, or when the group would get too long to read at a glance.
    public func chunk(at start: Int) -> Range<Int> {
        guard start < tokenCount else { return tokenCount..<tokenCount }
        var end = start + 1
        var characters = document.tokens[start].text.count
        let auto = chunkSize == Self.auto
        let limit = auto ? autoMaxCharacters : maxChunkCharacters
        if auto && !isFunctionWord(document.tokens[start]) { return start..<end }
        while end < tokenCount, end - start < (auto ? 2 : chunkSize) {
            let previous = document.tokens[end - 1]
            let next = document.tokens[end]
            if previous.pause != .none { break }
            if previous.continues || previous.isContinuation || next.continues || next.isContinuation { break }
            if characters + 1 + next.text.count > limit { break }
            if auto && !isFunctionWord(next) { break }
            characters += 1 + next.text.count
            end += 1
        }
        return start..<end
    }

    /// "it", "a", "is", "to"... with any surrounding punctuation ignored; never a word that carries
    /// meaning, a number or a link.
    private func isFunctionWord(_ token: Token) -> Bool {
        guard !token.isLink else { return false }
        return Self.functionWords.contains(token.text.lowercased().filter { $0.isLetter })
            && !token.text.contains(where: { $0.isNumber })
    }

    /// Moves to the next chunk. Returns false (and stays put) at the end.
    @discardableResult
    public func advance() -> Bool {
        let next = currentRange.upperBound
        guard next < tokenCount else { return false }
        index = next
        return true
    }

    /// One token forward or back (used while paused).
    public func step(_ delta: Int) {
        guard tokenCount > 0 else { return }
        index = min(tokenCount - 1, max(0, index + delta))
    }

    /// Back to the start of this sentence, or to the previous one when already at a sentence start.
    public func rewindSentence() {
        guard tokenCount > 0 else { return }
        let s = document.tokens[index].sentence
        let start = document.sentenceStarts[s]
        if index == start, s > 0 {
            index = document.sentenceStarts[s - 1]
        } else {
            index = start
        }
    }

    /// To the start of the next sentence (stays on the last one).
    public func forwardSentence() {
        guard tokenCount > 0 else { return }
        let s = document.tokens[index].sentence
        if s + 1 < document.sentenceStarts.count { index = document.sentenceStarts[s + 1] }
    }

    public func seek(to tokenIndex: Int) {
        guard tokenCount > 0 else { return }
        index = min(tokenCount - 1, max(0, tokenIndex))
    }

    public func restart() { index = 0 }
}
