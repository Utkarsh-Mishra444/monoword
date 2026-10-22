import Foundation
import MonowordCore

// monoword-schedule: prints the reader's timetable for a text, one flash per line, so another
// player (the Claude Code plugin's terminal band) shows the words with the app's own timing.
//
//   monoword-schedule <text file, or - for standard input> [wpm, default 500]
//                     [--chunk auto|1|2|3] [--frames <hz>]
//
// Output, tab separated: what the flash shows, how long it is held in seconds, and how many source
// words it starts (0 for the later pieces of a split word, 2 for a pair). Then one comment line
// with the totals. The settings are a new install's: adaptive pacing, auto grouping, real speed,
// ease-in, normal pauses, short links. --frames <hz> holds each flash a whole number of frames at
// that rate, as the app's frame clock does (60 reproduces `Monoword --render`'s frames.txt);
// without it the holds are the exact seconds the timing code asks for.

let usage = "usage: monoword-schedule <text file | -> [wpm, default 500] [--chunk auto|1|2|3] [--frames <hz>]"
let wpmRange = 100...1500   // the app's speed range (Settings.wpmRange)

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(2)
}

var positional: [String] = []
var chunk = ReadingSession.auto
var frames: Double?
var args = Array(CommandLine.arguments.dropFirst())
while !args.isEmpty {
    let a = args.removeFirst()
    switch a {
    case "--chunk":
        guard let v = args.first else { fail(usage) }
        args.removeFirst()
        switch v {
        case "auto": chunk = ReadingSession.auto
        case "1", "2", "3": chunk = Int(v)!
        default: fail("--chunk takes auto, 1, 2 or 3\n\(usage)")
        }
    case "--frames":
        guard let v = args.first, let hz = Double(v), hz >= 10, hz <= 480 else { fail("--frames takes a display rate in Hz, such as 60\n\(usage)") }
        args.removeFirst()
        frames = hz
    case "-h", "--help":
        print(usage)
        exit(0)
    default:
        if a.hasPrefix("--") { fail("unknown option \(a)\n\(usage)") }
        positional.append(a)
    }
}
guard (1...2).contains(positional.count) else { fail(usage) }
let wpm = positional.count > 1 ? Int(positional[1]) : 500
guard let wpm, wpmRange.contains(wpm) else {
    fail("wpm must be a whole number from \(wpmRange.lowerBound) to \(wpmRange.upperBound)\n\(usage)")
}

let text: String
if positional[0] == "-" {
    text = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
} else {
    let url = URL(fileURLWithPath: (positional[0] as NSString).expandingTildeInPath)
    guard let t = try? String(contentsOf: url, encoding: .utf8) else { fail("cannot read \(url.path)") }
    text = t
}

/// The word frequency list adaptive pacing needs: $MONOWORD_FREQUENCY_LIST, else beside the tool in
/// an app bundle (Contents/MacOS/.. /Resources), else the Resources folder of the checkout it was
/// built from (as the app's debug build finds it).
func frequencyListURL() -> URL? {
    let fm = FileManager.default
    if let env = ProcessInfo.processInfo.environment["MONOWORD_FREQUENCY_LIST"], !env.isEmpty {
        return URL(fileURLWithPath: env)
    }
    let exe = URL(fileURLWithPath: CommandLine.arguments[0]).resolvingSymlinksInPath()
    let bundled = exe.deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Resources/word-frequency-en.txt")
    if fm.fileExists(atPath: bundled.path) { return bundled }
    let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Resources/word-frequency-en.txt")
    if fm.fileExists(atPath: repo.path) { return repo }
    return nil
}
guard let listURL = frequencyListURL(), let list = try? String(contentsOf: listURL, encoding: .utf8) else {
    fail("word frequency list not found (adaptive pacing needs it); set MONOWORD_FREQUENCY_LIST to Resources/word-frequency-en.txt")
}

let timing = TimingOptions(wpm: Double(wpm), punctuationPause: 1, lengthPause: true, rampUp: true,
                           adaptive: true, realSpeed: true)
let schedule = Schedule(text: text, timing: timing, chunkSize: chunk, frequency: FrequencyTable(listText: list),
                        frameRate: frames ?? 60, quantize: frames != nil)

var out = ""
out.reserveCapacity(schedule.flashes.count * 24)
for f in schedule.flashes {
    let shown = f.text.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\n", with: " ")
    out += "\(shown)\t\(String(format: "%.6f", f.seconds))\t\(f.words)\n"
}
let total = schedule.total
let real = total > 0 ? Double(schedule.wordCount) / total * 60 : 0
out += String(format: "# words %d\tflashes %d\ttotal %.6f\twpm %d\treal %.2f\tchunk %@\tframes %@",
              schedule.wordCount, schedule.flashes.count, total, wpm, real,
              chunk == ReadingSession.auto ? "auto" : String(chunk),
              frames.map { String(format: "%g", $0) } ?? "exact")
if let reachable = schedule.clock.reachableWPM {
    out += String(format: "\treachable %.2f", reachable)
}
out += "\n"
FileHandle.standardOutput.write(Data(out.utf8))
