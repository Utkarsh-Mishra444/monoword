import AppKit
import CoreText

/// Draws the reader: the word centred between two guide lines, the header, the context line shown
/// while paused, the footer and the progress bar. Everything is drawn by hand, so a frame costs
/// one CoreText line and nothing moves but the word.
final class ReaderView: NSView {

    struct State {
        var word = ""
        var isLink = false
        var header = ""
        var speed = ""
        var speedFlash = false
        var footer = ""
        var progress = 0.0
        var playing = false
        var context: NSAttributedString?
        var message: String?
        var messageDetail: String?
        var banner: String?
        var showHelp = false
    }

    var state = State() { didSet { needsDisplay = true } }
    var theme: Theme = .dark { didSet { needsDisplay = true } }
    var wordFont: NSFont = .systemFont(ofSize: 46, weight: .medium) { didSet { needsDisplay = true } }
    var showGuides = true { didSet { needsDisplay = true } }

    var onToggle: (() -> Void)?
    var onAllow: (() -> Void)?
    var onScrub: ((Int) -> Void)?

    static let padding: CGFloat = 22
    static let headerHeight: CGFloat = 36
    static let contextHeight: CGFloat = 66
    static let footerHeight: CGFloat = 30
    static let cornerRadius: CGFloat = 16

    static func wordAreaHeight(fontSize: CGFloat) -> CGFloat { max(96, (fontSize * 2.05).rounded()) }

    static func preferredHeight(fontSize: CGFloat) -> CGFloat {
        headerHeight + wordAreaHeight(fontSize: fontSize) + contextHeight + footerHeight
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // MARK: - Geometry

    var wordArea: NSRect {
        NSRect(x: 0, y: Self.headerHeight, width: bounds.width,
               height: Self.wordAreaHeight(fontSize: wordFont.pointSize))
    }
    private var contextArea: NSRect {
        NSRect(x: Self.padding + 8, y: wordArea.maxY + 2, width: bounds.width - 2 * (Self.padding + 8),
               height: Self.contextHeight - 8)
    }
    private var bannerButtonRect = NSRect.zero

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: Self.cornerRadius, yRadius: Self.cornerRadius)
        theme.background.setFill()
        shape.fill()
        theme.border.setStroke()
        shape.lineWidth = 1
        shape.stroke()

        drawHeader()
        if showGuides && state.message == nil { drawGuides() }
        if let message = state.message {
            drawMessage(message, detail: state.messageDetail)
        } else if !state.word.isEmpty {
            drawWord()
        }
        if state.showHelp {
            drawHelp()
        } else if !state.playing, let context = state.context {
            context.draw(with: contextArea, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
        drawFooter()
    }

    private func label(_ s: String, size: CGFloat = 11.5, weight: NSFont.Weight = .medium,
                       color: NSColor? = nil, monoDigits: Bool = true) -> NSAttributedString {
        let font = monoDigits ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
                              : NSFont.systemFont(ofSize: size, weight: weight)
        return NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color ?? theme.secondary])
    }

    private func drawHeader() {
        let p = Self.padding
        let y: CGFloat = 13
        if let banner = state.banner {
            let rect = NSRect(x: p - 8, y: 7, width: bounds.width - 2 * (p - 8), height: 26)
            theme.accent.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).fill()
            let button = label("Allow…", size: 11.5, weight: .semibold, color: .white, monoDigits: false)
            let bw = button.size().width + 20
            bannerButtonRect = NSRect(x: rect.maxX - bw - 4, y: rect.minY + 3, width: bw, height: rect.height - 6)
            theme.accent.setFill()
            NSBezierPath(roundedRect: bannerButtonRect, xRadius: 5, yRadius: 5).fill()
            button.draw(at: NSPoint(x: bannerButtonRect.minX + 10, y: bannerButtonRect.minY + 3))
            let text = label(banner, size: 11.5, weight: .medium, color: theme.text, monoDigits: false)
            text.draw(with: NSRect(x: rect.minX + 10, y: rect.minY + 6, width: bannerButtonRect.minX - rect.minX - 16, height: 16),
                      options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
            return
        }
        bannerButtonRect = .zero
        label(state.header).draw(at: NSPoint(x: p, y: y))
        let speed = label(state.speed, color: state.speedFlash ? theme.accent : nil)
        speed.draw(at: NSPoint(x: bounds.width - p - speed.size().width, y: y))
    }

    private func drawGuides() {
        let area = wordArea
        let top = area.minY + 8, bottom = area.maxY - 8
        let p = Self.padding
        theme.guide.setFill()
        NSRect(x: p, y: top, width: bounds.width - 2 * p, height: 1).fill()
        NSRect(x: p, y: bottom - 1, width: bounds.width - 2 * p, height: 1).fill()
        #if LOCAL_EXTENSIONS
        drawLocalGuideMarks(top: top, bottom: bottom)
        #endif
    }

    /// The word as one CoreText line in the text colour, shrunk if it would not fit.
    func wordLine(_ word: String, coloring: ((NSMutableAttributedString) -> Void)? = nil) -> (CTLine, NSFont, CGFloat) {
        func make(_ font: NSFont) -> CTLine {
            let s = NSMutableAttributedString(string: word, attributes: [
                .font: font,
                NSAttributedString.Key(kCTForegroundColorAttributeName as String): theme.text.cgColor,
            ])
            coloring?(s)
            return CTLineCreateWithAttributedString(s)
        }
        var font = wordFont
        var line = make(font)
        var width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        let available = bounds.width - 2 * Self.padding
        if width > available {
            font = NSFont(descriptor: font.fontDescriptor, size: font.pointSize * available / width * 0.97) ?? font
            line = make(font)
            width = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        }
        return (line, font, width)
    }

    private func drawWord() {
        #if LOCAL_EXTENSIONS
        if drawLocalWord() { return }
        #endif
        let (line, font, width) = wordLine(state.word)
        draw(line, x: (bounds.width - width) / 2, font: font)
    }

    /// Draws a word line with its baseline centred in the word area.
    func draw(_ line: CTLine, x: CGFloat, font: NSFont) {
        let baseline = (wordArea.midY + font.capHeight / 2).rounded()
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        ctx.saveGState()
        ctx.textMatrix = .identity
        ctx.translateBy(x: x.rounded(), y: baseline)
        ctx.scaleBy(x: 1, y: -1)
        ctx.textPosition = .zero
        CTLineDraw(line, ctx)
        ctx.restoreGState()
    }

    private func drawMessage(_ message: String, detail: String?) {
        let area = wordArea
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        let title = NSAttributedString(string: message, attributes: [
            .font: NSFont.systemFont(ofSize: 22, weight: .semibold), .foregroundColor: theme.text, .paragraphStyle: style,
        ])
        let titleHeight = title.boundingRect(with: NSSize(width: area.width - 60, height: 200), options: .usesLineFragmentOrigin).height
        var y = area.midY - titleHeight / 2
        if detail != nil { y -= 10 }
        title.draw(with: NSRect(x: 30, y: y, width: area.width - 60, height: titleHeight + 4), options: .usesLineFragmentOrigin)
        if let detail {
            let d = NSAttributedString(string: detail, attributes: [
                .font: NSFont.systemFont(ofSize: 12.5, weight: .regular), .foregroundColor: theme.secondary, .paragraphStyle: style,
            ])
            d.draw(with: NSRect(x: 40, y: y + titleHeight + 6, width: area.width - 80, height: 60),
                   options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        }
    }

    private static let helpRows: [(String, String, String, String)] = [
        ("space", "play / pause", "↑ ↓", "speed ±25  (⇧ ±100)"),
        ("← →", "sentence back / next", "⇧← ⇧→", "one word"),
        ("1 2 3 a", "words per flash", "[ ]", "text size"),
        ("r", "restart", "t", "theme   ·   esc  close"),
    ]

    private func drawHelp() {
        let area = contextArea
        let rowHeight: CGFloat = 15
        let keyWidth: CGFloat = 52
        let column = area.width / 2
        for (i, row) in Self.helpRows.enumerated() {
            let y = area.minY + CGFloat(i) * rowHeight
            label(row.0, size: 11, weight: .semibold, color: theme.text).draw(at: NSPoint(x: area.minX + 10, y: y))
            label(row.1, size: 11).draw(at: NSPoint(x: area.minX + 10 + keyWidth, y: y))
            label(row.2, size: 11, weight: .semibold, color: theme.text).draw(at: NSPoint(x: area.minX + column, y: y))
            label(row.3, size: 11).draw(at: NSPoint(x: area.minX + column + keyWidth, y: y))
        }
    }

    private func drawFooter() {
        let p = Self.padding
        let barY = bounds.height - 11
        let track = NSRect(x: p, y: barY, width: bounds.width - 2 * p, height: 3)
        theme.guide.setFill()
        NSBezierPath(roundedRect: track, xRadius: 1.5, yRadius: 1.5).fill()
        if state.progress > 0 {
            var fill = track
            fill.size.width = max(3, track.width * min(1, state.progress))
            theme.accent.withAlphaComponent(0.85).setFill()
            NSBezierPath(roundedRect: fill, xRadius: 1.5, yRadius: 1.5).fill()
        }
        let y = bounds.height - Self.footerHeight + 1
        label(state.footer, size: 11).draw(at: NSPoint(x: p, y: y))
        if !state.playing && !state.showHelp {
            let hint = label("space play   ← → sentence   ↑ ↓ speed   ? keys   esc", size: 11)
            hint.draw(at: NSPoint(x: bounds.width - p - hint.size().width, y: y))
        }
    }

    // MARK: - Mouse

    private var dragOrigin: NSPoint?
    private var dragged = false
    private var scrollAccumulator: CGFloat = 0

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        if bannerButtonRect.contains(point) {
            onAllow?()
            dragOrigin = nil
            return
        }
        dragOrigin = NSEvent.mouseLocation
        dragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let origin = dragOrigin, let window else { return }
        let now = NSEvent.mouseLocation
        let dx = now.x - origin.x, dy = now.y - origin.y
        if !dragged && hypot(dx, dy) < 3 { return }
        dragged = true
        window.setFrameOrigin(NSPoint(x: window.frame.minX + dx, y: window.frame.minY + dy))
        dragOrigin = now
    }

    override func mouseUp(with event: NSEvent) {
        defer { dragOrigin = nil }
        if dragOrigin != nil && !dragged { onToggle?() }
    }

    override func scrollWheel(with event: NSEvent) {
        let step: CGFloat = event.hasPreciseScrollingDeltas ? 14 : 1
        scrollAccumulator += event.scrollingDeltaY
        while scrollAccumulator <= -step { scrollAccumulator += step; onScrub?(1) }
        while scrollAccumulator >= step { scrollAccumulator -= step; onScrub?(-1) }
        if event.phase == .ended || event.momentumPhase == .ended { scrollAccumulator = 0 }
    }
}
