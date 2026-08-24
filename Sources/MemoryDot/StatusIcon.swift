import AppKit

enum StatusIcon {
	static func createDotImage(for level: PressureLevel, size: CGFloat = 20) -> NSImage {
		let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
			let inset: CGFloat = 2.5
			let dotRect = rect.insetBy(dx: inset, dy: inset)
			let path = NSBezierPath(ovalIn: dotRect)
			level.color.setFill()
			path.fill()

			let letter = level.glyph as NSString
			let fontSize: CGFloat = dotRect.height * (letter.length > 1 ? 0.45 : 0.6)
			let attributes: [NSAttributedString.Key: Any] = [
				.font: NSFont.systemFont(ofSize: fontSize, weight: .bold),
				.foregroundColor: NSColor.white,
			]
			let textSize = letter.size(withAttributes: attributes)
			let textRect = CGRect(
				x: dotRect.midX - textSize.width / 2,
				y: dotRect.midY - textSize.height / 2,
				width: textSize.width,
				height: textSize.height
			)
			letter.draw(in: textRect, withAttributes: attributes)

			return true
		}
		image.isTemplate = false
		image.accessibilityDescription = "Memory pressure: \(level.displayName)"
		return image
	}
}
