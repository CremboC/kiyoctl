import AppKit

enum KiyoMenuIcon {
    /// A code-drawn template image lets AppKit supply the correct foreground
    /// color for light, dark and highlighted menu-bar appearances.
    static func apertureTemplate() -> NSImage {
        let size = NSSize(width: 18, height: 18)
        let image = NSImage(size: size, flipped: false) { rect in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }

            context.saveGState()
            defer { context.restoreGState() }
            context.translateBy(x: rect.midX, y: rect.midY)
            context.scaleBy(x: rect.width / 18, y: rect.height / 18)
            context.setFillColor(NSColor.black.cgColor)

            for index in 0..<5 {
                context.saveGState()
                context.rotate(by: CGFloat(index) * 2 * .pi / 5)

                let blade = CGMutablePath()
                // Keep the complete blade inside a 65° sector. Five rotated
                // copies therefore retain visible gaps instead of merging
                // into a solid disc when AppKit downsamples them to 18 px.
                blade.move(to: CGPoint(x: 1.6, y: 2.5))
                blade.addCurve(
                    to: CGPoint(x: 5.2, y: 6.7),
                    control1: CGPoint(x: 3.5, y: 3.8),
                    control2: CGPoint(x: 4.9, y: 5.4))
                blade.addCurve(
                    to: CGPoint(x: -1.7, y: 7.3),
                    control1: CGPoint(x: 3.4, y: 7.6),
                    control2: CGPoint(x: 0.7, y: 7.8))
                blade.addCurve(
                    to: CGPoint(x: 1.6, y: 2.5),
                    control1: CGPoint(x: -0.9, y: 5.5),
                    control2: CGPoint(x: 0.4, y: 3.5))
                blade.closeSubpath()

                context.addPath(blade)
                context.fillPath()
                context.restoreGState()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
