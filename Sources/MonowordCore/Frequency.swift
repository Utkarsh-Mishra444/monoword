import Foundation

/// English word frequencies as Zipf values (log10 of occurrences per billion words): about 7 for
/// "the", 5 for "however", 2.5 for "photosynthesis". Built from a "word count" list, most frequent
/// first (Resources/word-frequency-en.txt: OpenSubtitles 2018 via hermitdave/FrequencyWords,
/// CC BY-SA 4.0).
public struct FrequencyTable: Sendable {
    private let zipf: [String: Double]
    /// Zipf assumed for a word that is not in the list (rarer than anything in it).
    public static let unknownZipf = 1.5

    public init(listText: String) {
        var counts: [(Substring, Double)] = []
        counts.reserveCapacity(50_000)
        var total = 0.0
        for line in listText.split(separator: "\n") {
            guard let space = line.lastIndex(of: " "),
                  let count = Double(line[line.index(after: space)...].trimmingCharacters(in: .whitespaces)) else { continue }
            counts.append((line[..<space], count))
            total += count
        }
        var table: [String: Double] = [:]
        table.reserveCapacity(counts.count)
        if total > 0 {
            for (word, count) in counts where table[String(word)] == nil {
                table[String(word)] = log10(count / total * 1e9)
            }
        }
        zipf = table
    }

    public var count: Int { zipf.count }

    /// Zipf of a token as shown in text ("However," "don't" "well-known"), or nil when it has no
    /// letters. The list splits contractions, so "don't" is looked up as "don"; a hyphenated
    /// compound counts as its rarest part.
    public func zipf(of token: String) -> Double? {
        let parts = token.lowercased().split(whereSeparator: { $0 == "-" || $0 == "–" || $0 == "/" })
        var result: Double?
        for part in parts {
            let letters = part.drop(while: { !$0.isLetter })
            let word = letters.prefix(while: { $0.isLetter })
            guard !word.isEmpty else { continue }
            let z = zipf[String(word)] ?? Self.unknownZipf
            result = min(result ?? z, z)
        }
        return result
    }
}
