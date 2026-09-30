import AppKit
import MeowMacCore

public enum CatRenderer {
    public static func image(frame: Int, level: HealthLevel, size: CGSize = CGSize(width: 28, height: 18)) -> NSImage {
        let color: NSColor
        switch level {
        case .normal: color = .black
        case .warn: color = .systemOrange
        case .severe: color = .systemRed
        }
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.setFillColor(color.cgColor)
            context.setStrokeColor(color.cgColor)
            let ratio = size.height / 18
            context.scaleBy(x: ratio, y: ratio)
            if level == .severe {
                context.fillEllipse(in: CGRect(x: 4, y: 2, width: 17, height: 8))
                context.fillEllipse(in: CGRect(x: 18, y: 5, width: 8, height: 7))
                context.move(to: CGPoint(x: 19, y: 11)); context.addLine(to: CGPoint(x: 20, y: 16)); context.addLine(to: CGPoint(x: 23, y: 12)); context.closePath(); context.fillPath()
                context.move(to: CGPoint(x: 23, y: 12)); context.addLine(to: CGPoint(x: 26, y: 16)); context.addLine(to: CGPoint(x: 26, y: 9)); context.closePath(); context.fillPath()
            } else {
                let phase = CGFloat(frame % 5) * 2 * .pi / 5
                context.fillEllipse(in: CGRect(x: 6, y: 5, width: 15, height: 8))
                context.fillEllipse(in: CGRect(x: 18, y: 9, width: 7, height: 6))
                context.move(to: CGPoint(x: 19, y: 14)); context.addLine(to: CGPoint(x: 20, y: 18)); context.addLine(to: CGPoint(x: 23, y: 15)); context.closePath(); context.fillPath()
                context.move(to: CGPoint(x: 23, y: 15)); context.addLine(to: CGPoint(x: 26, y: 18)); context.addLine(to: CGPoint(x: 25, y: 12)); context.closePath(); context.fillPath()
                context.setLineWidth(2)
                for (index, x) in [9.0, 13.0, 18.0, 21.0].enumerated() {
                    let stride = sin(phase + CGFloat(index) * .pi) * 3
                    context.move(to: CGPoint(x: x, y: 7))
                    context.addLine(to: CGPoint(x: x + stride, y: 1))
                }
                context.strokePath()
                context.move(to: CGPoint(x: 7, y: 9))
                context.addCurve(to: CGPoint(x: 2, y: 15), control1: CGPoint(x: 2, y: 6), control2: CGPoint(x: 1, y: 11))
                context.strokePath()
            }
            return true
        }
        image.isTemplate = level == .normal
        return image
    }

    public static func png(frame: Int, level: HealthLevel, pixelSize: Int = 180) -> Data {
        let image = self.image(frame: frame, level: level, size: CGSize(width: CGFloat(pixelSize) * 28 / 18, height: CGFloat(pixelSize)))
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
