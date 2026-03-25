import AppKit

enum StatusIcon {
	static func createDotImage(color: NSColor, size: CGFloat = 18) -> NSImage {
		let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
			let inset: CGFloat = 3
			let dotRect = rect.insetBy(dx: inset, dy: inset)
			let path = NSBezierPath(ovalIn: dotRect)
			color.setFill()
			path.fill()

			let letter = "M" as NSString
			let fontSize: CGFloat = dotRect.height * 0.55
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
		return image
	}
}
