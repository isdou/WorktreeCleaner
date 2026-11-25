import AppKit

/// 极简几何菜单栏模板图标（16x16pt，isTemplate = true）
enum MenuBarIconRenderer {
    @MainActor
    static let templateImage: NSImage = {
        let size = NSSize(width: 16, height: 16)
        let image = NSImage(size: size, flipped: false) { _ in
            NSColor.labelColor.setStroke()
            NSColor.labelColor.setFill()

            let trunk = NSBezierPath()
            trunk.lineWidth = 1.65
            trunk.lineCapStyle = .round
            trunk.move(to: NSPoint(x: 4.6, y: 3.6))
            trunk.line(to: NSPoint(x: 4.6, y: 12.4))
            trunk.stroke()

            let branch = NSBezierPath()
            branch.lineWidth = 1.65
            branch.lineCapStyle = .round
            branch.move(to: NSPoint(x: 4.6, y: 5.2))
            branch.curve(
                to: NSPoint(x: 11.4, y: 10.6),
                controlPoint1: NSPoint(x: 4.6, y: 8.6),
                controlPoint2: NSPoint(x: 11.4, y: 7.2)
            )
            branch.stroke()

            func dot(_ x: CGFloat, _ y: CGFloat, r: CGFloat = 1.8) {
                NSBezierPath(ovalIn: NSRect(x: x - r, y: y - r, width: r * 2, height: r * 2)).fill()
            }
            dot(4.6, 3.1)
            dot(4.6, 12.9)
            dot(11.4, 11.1)

            return true
        }
        image.isTemplate = true
        return image
    }()
}
