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

    /// The icon with Apple's small "attention" dot at the top right. Template images can't carry
    /// colour, so this is a plain image drawn in the menu bar's label colour for `appearance`
    /// (rebuild it when the appearance changes).
    static func makeBadged(appearance: NSAppearance, size: CGFloat = 18) -> NSImage {
        let template = make(size: size)
        let canvas = template.size
        let image = NSImage(size: canvas, flipped: false) { rect in
            appearance.performAsCurrentDrawingAppearance {
                guard let ctx = NSGraphicsContext.current else { return }
                // Icon tinted with the label colour.
                template.draw(in: rect)
                ctx.compositingOperation = .sourceAtop
                NSColor.labelColor.setFill()
                rect.fill()

                // Knock a small gap around the dot so it reads cleanly over the pill outline.
                let dot = size * 0.30
                let dotRect = NSRect(x: rect.maxX - dot, y: rect.maxY - dot - size * 0.08, width: dot, height: dot)
                ctx.compositingOperation = .clear
                NSBezierPath(ovalIn: dotRect.insetBy(dx: -1.25, dy: -1.25)).fill()
                ctx.compositingOperation = .sourceOver
                NSColor.systemRed.setFill()
                NSBezierPath(ovalIn: dotRect).fill()
            }
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "Notch, update available"
        return image
    }
}
