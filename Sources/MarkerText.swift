import Cocoa

/// Draws a leading status emoji smaller than the text next to it.
enum MarkerText {
    /// Marker size relative to the text font.
    static let markerScale: CGFloat = 0.8

    static func attributed(_ text: String, font: NSFont, color: NSColor? = nil) -> NSAttributedString {
        var base: [NSAttributedString.Key: Any] = [.font: font]
        if let color = color { base[.foregroundColor] = color }
        let result = NSMutableAttributedString(string: text, attributes: base)

        guard let first = text.first, isEmojiMarker(first) else { return result }
        let small = NSFont.systemFont(ofSize: (font.pointSize * markerScale).rounded(), weight: .regular)
        let range = NSRange(text.startIndex...text.startIndex, in: text)
        result.addAttributes([
            .font: small,
            // Keep the smaller glyph vertically centred on the text line.
            .baselineOffset: (font.pointSize - small.pointSize) * 0.28
        ], range: range)
        return result
    }

    private static func isEmojiMarker(_ ch: Character) -> Bool {
        guard let scalar = ch.unicodeScalars.first, scalar.value > 0x2000 else { return false }
        return scalar.properties.isEmojiPresentation || ch.unicodeScalars.contains { $0.value == 0xFE0F }
    }
}
