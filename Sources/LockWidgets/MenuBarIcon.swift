import AppKit

/// Notch's menu bar glyph: the island pill with an art dot and three waveform bars, matching the
/// app icon. Drawn as a template image so it follows the menu bar's light/dark appearance.
enum MenuBarIcon {
    static func make(size: CGFloat = 18) -> NSImage {
        let width = size * 1.45
        let image = NSImage(size: NSSize(width: width, height: size), flipped: false) { rect in
            let pillHeight = size * 0.62
            let pill = NSRect(x: rect.minX + 0.75, y: rect.midY - pillHeight / 2, width: rect.width - 1.5, height: pillHeight)
            let path = NSBezierPath(roundedRect: pill, xRadius: pillHeight / 2, yRadius: pillHeight / 2)
            path.lineWidth = 1.5
            NSColor.black.setStroke()
            path.stroke()

            // Art dot
            let dot = pillHeight * 0.52
            NSColor.black.setFill()
            NSBezierPath(ovalIn: NSRect(x: pill.minX + pillHeight * 0.24, y: pill.midY - dot / 2, width: dot, height: dot)).fill()

            // Waveform bars
            let barWidth = size * 0.085
            let gap = size * 0.07
            let levels: [CGFloat] = [0.45, 0.85, 0.6]
            var x = pill.maxX - pillHeight * 0.32 - CGFloat(levels.count) * barWidth - CGFloat(levels.count - 1) * gap
            for level in levels {
                let h = pillHeight * 0.62 * level
                NSBezierPath(roundedRect: NSRect(x: x, y: pill.midY - h / 2, width: barWidth, height: h),
                             xRadius: barWidth / 2, yRadius: barWidth / 2).fill()
                x += barWidth + gap
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Notch"
        return image
    }
}
