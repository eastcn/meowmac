import AppKit
import MeowMacCore

public struct CatDisplay: Codable {
    public let level: HealthLevel
    public let load: Double, frameInterval: Double
    public let speedLines: Bool, template: Bool, stopped: Bool, reducedMotion: Bool
    public func frame(_ requested: Int) -> Int { stopped || reducedMotion ? 0 : (requested % 5 + 5) % 5 }
}
public extension PanelState {
    func catDisplay(reducedMotion: Bool = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion) -> CatDisplay {
        let load = min(1, max(0, max(snapshot?.cpuUsage ?? 0, snapshot?.memoryPressure.load(config: configResult.config) ?? 0)))
        return CatDisplay(level: health.level, load: load, frameInterval: CatMotion.frameInterval(load: load, config: configResult.config),
            speedLines: load >= 0.7 && health.level != .severe, template: health.level == .normal, stopped: health.level == .severe, reducedMotion: reducedMotion)
    }
}

public enum CatRenderer {
    // MenuBar.dc.html 的 44×28 矢量路径，坐标、帧和笔宽保持原稿。
    private static let offsets: [Double] = [0, 0.8, 0.4, -0.8, -0.3]
    private static let legs = [
        "M27 18 L32 23 M25 18.5 L29 24 M13 18.5 L7 22 M15.5 19 L10 23.5",
        "M27 18.8 L27.5 25 M25 19.3 L24 25 M13 19.3 L12 25 M15.5 19.8 L16.5 25",
        "M27 18.4 L24.5 24.6 M25 18.9 L22 24 M13 18.9 L16.5 24.6 M15.5 19.4 L19.5 24.3",
        "M27 17.2 L30.5 20.4 M25 17.7 L27.5 21.4 M13 17.7 L9.5 20.4 M15.5 18.2 L12.5 21.4",
        "M27 17.7 L31.5 21.9 M25 18.2 L27 23.4 M13 18.2 L8.5 22.4 M15.5 18.7 L13 23.9"]
    private static let tails = ["M9.5 13.5 C6 12.5 3.8 10.2 4.4 6.2", "M9.5 14.3 C6 13.8 4 12.3 3.6 8.8", "M9.5 13.9 C6 13.9 4.2 12.9 3.2 10.4", "M9.5 12.7 C6 11.2 4.5 8.2 5.5 4.7", "M9.5 13.2 C6 11.9 4 9.5 4.6 6.3"]
    private static func path(_ text: String) -> CGPath {
        let expression = try! NSRegularExpression(pattern: "[MLCHVZ]|-?[0-9]+(?:\\.[0-9]+)?")
        let source = text as NSString
        let tokens = expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
        let path = CGMutablePath(); var index = 0
        func number() -> CGFloat { defer { index += 1 }; return CGFloat(Double(tokens[index])!) }
        func point() -> CGPoint { CGPoint(x: number(), y: number()) }
        while index < tokens.count {
            let command = tokens[index]; index += 1
            switch command {
            case "M": path.move(to: point())
            case "L": path.addLine(to: point())
            case "C": let a = point(), b = point(), end = point(); path.addCurve(to: end, control1: a, control2: b)
            case "H": path.addLine(to: CGPoint(x: number(), y: path.currentPoint.y))
            case "V": path.addLine(to: CGPoint(x: path.currentPoint.x, y: number()))
            case "Z": path.closeSubpath()
            default: preconditionFailure("猫路径包含未支持的命令")
            }
        }
        return path
    }
    public static func image(frame: Int, level: HealthLevel, load: Double = 0, reducedMotion: Bool = false, size: CGSize = CGSize(width: 28, height: 18)) -> NSImage {
        let color: NSColor = level == .normal ? .black : level == .warn ? .systemOrange : .systemRed
        let index = reducedMotion ? 0 : (frame % 5 + 5) % 5
        let image = NSImage(size: size, flipped: false) { _ in
            guard let context = NSGraphicsContext.current?.cgContext else { return false }
            context.translateBy(x: 0, y: size.height)
            context.scaleBy(x: size.width / 44, y: -size.height / 28)
            context.setFillColor(color.cgColor); context.setStrokeColor(color.cgColor); context.setLineCap(.round)
            func fill(_ text: String) { context.addPath(path(text)); context.fillPath() }
            func stroke(_ text: String, _ width: CGFloat) { context.addPath(path(text)); context.setLineWidth(width); context.strokePath() }
            if level == .severe {
                fill("M7 24.5 C7 18.5 12 16 19 16 C25 16 28.5 17.5 29.5 20 L29.5 24.5 Z")
                context.fillEllipse(in: CGRect(x: 26.5, y: 15.5, width: 9, height: 9))
                fill("M27.8 17.3 L28.4 12.9 L31 15.9 Z M31.6 15.7 L34.4 12.7 L34.8 17.5 Z")
                stroke("M7.5 23.5 C4 23.5 3 26 5.5 26.2 L20 26.2", 2.2)
                stroke("M34 5 H37 L34 8 H37 M38.5 1.5 H40.5 L38.5 3.5 H40.5", 1.3)
            } else {
                let d = offsets[index]
                fill("M9 \(15+d) C9 \(10.5+d) 14 \(9+d) 20 \(9.5+d) C25 \(10+d) 28 \(10.5+d) 29.5 \(12+d) L30 \(17+d) C28 \(19.5+d) 23 \(20+d) 18 \(19.8+d) C12.5 \(19.6+d) 9 \(18.5+d) 9 \(15+d) Z")
                context.fillEllipse(in: CGRect(x: 27, y: 7+d, width: 9, height: 9))
                fill("M28.4 \(8.6+d) L29.2 \(4+d) L32 \(7.2+d) Z M32.2 \(7+d) L35 \(3.8+d) L35.6 \(8.8+d) Z")
                stroke(tails[index], 2.2); stroke(legs[index], 2.4)
                if load >= 0.7 { stroke("M0.6 16 H3.2 M0 19.5 H2.6 M0.6 23 H3.2", 1.3) }
            }
            return true
        }
        image.isTemplate = level == .normal
        return image
    }
    public static func png(frame: Int, level: HealthLevel, load: Double = 0, reducedMotion: Bool = false, pixelSize: Int = 72) -> Data {
        let image = image(frame: frame, level: level, load: load, reducedMotion: reducedMotion, size: CGSize(width: CGFloat(pixelSize) * 44 / 28, height: CGFloat(pixelSize)))
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return Data() }
        return rep.representation(using: .png, properties: [:]) ?? Data()
    }
}
