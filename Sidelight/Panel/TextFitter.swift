import AppKit

enum TextFitter {
    static let minSize: CGFloat = 40
    static let maxSize: CGFloat = 220

    /// Largest font size in [minSize, maxSize] at which `text` fits inside `box`.
    static func fontSize(for text: String, in box: CGSize, weight: NSFont.Weight = .semibold) -> CGFloat {
        guard !text.isEmpty else { return minSize }
        var lo = minSize, hi = maxSize
        while hi - lo > 0.5 {
            let mid = (lo + hi) / 2
            if fits(text, size: mid, box: box, weight: weight) { lo = mid } else { hi = mid }
        }
        return lo.rounded(.down)
    }

    private static func fits(_ text: String, size: CGFloat, box: CGSize, weight: NSFont.Weight) -> Bool {
        let style = NSMutableParagraphStyle()
        style.alignment = .center
        style.lineHeightMultiple = 1.02
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: size, weight: weight),
            .paragraphStyle: style
        ]
        let rect = (text as NSString).boundingRect(
            with: CGSize(width: box.width, height: .greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: attrs)
        guard rect.height <= box.height else { return false }
        return widestWord(in: text, attributes: attrs) <= box.width
    }

    /// `boundingRect` falls back to breaking a word mid-character when it is wider than the
    /// line. The spec forbids that, so a size only "fits" if every word fits on one line.
    private static func widestWord(in text: String, attributes: [NSAttributedString.Key: Any]) -> CGFloat {
        var widest: CGFloat = 0
        for word in text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }) {
            let width = (String(word) as NSString).size(withAttributes: attributes).width
            widest = max(widest, width)
        }
        return widest
    }
}
