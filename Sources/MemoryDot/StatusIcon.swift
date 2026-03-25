import AppKit

enum StatusIcon {
    static func createDotImage(color: NSColor, size: CGFloat = 18) -> NSImage {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            let inset: CGFloat = 3
            let dotRect = rect.insetBy(dx: inset, dy: inset)
            let path = NSBezierPath(ovalIn: dotRect)
            color.setFill()
            path.fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
