import AppKit

public enum AppIcon {
    public static func png(size: Int) -> Data {
        let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
            NSColor.black.setFill()
            let body = NSBezierPath(ovalIn: rect.insetBy(dx: rect.width * 0.16, dy: rect.height * 0.3))
            body.fill()
            let head = NSBezierPath(ovalIn: CGRect(x: rect.width * 0.54, y: rect.height * 0.48,
                                                   width: rect.width * 0.32, height: rect.height * 0.28))
            head.fill()
            let ears = NSBezierPath()
            ears.move(to: CGPoint(x: rect.width * 0.59, y: rect.height * 0.68))
            ears.line(to: CGPoint(x: rect.width * 0.61, y: rect.height * 0.88))
            ears.line(to: CGPoint(x: rect.width * 0.71, y: rect.height * 0.75))
            ears.line(to: CGPoint(x: rect.width * 0.82, y: rect.height * 0.88))
            ears.line(to: CGPoint(x: rect.width * 0.82, y: rect.height * 0.65))
            ears.close()
            ears.fill()
            return true
        }
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return Data() }
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }
}
