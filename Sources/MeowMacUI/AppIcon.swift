import AppKit

public enum AppIcon {
    /// 使用用户确认的墨蓝像素图。原图不改色、不重画，仅缩放并裁出应用圆角边界。
    public static func png(size: Int) -> Data {
        guard (16...1024).contains(size),
              let url = Bundle.module.resourceURL?.appendingPathComponent("AppIcon-pixel-ink.png"),
              let data = try? Data(contentsOf: url),
              let source = NSBitmapImageRep(data: data)?.cgImage,
              let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                  bytesPerRow: size * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        // 使用明确像素尺寸，导出结果不受显示器缩放比例影响。
        let scale = CGFloat(size) / 1024
        context.scaleBy(x: scale, y: scale)
        let tile = CGRect(x: 64, y: 64, width: 896, height: 896)
        let outline = CGPath(roundedRect: tile, cornerWidth: 204, cornerHeight: 204, transform: nil)
        context.addPath(outline)
        context.clip()
        context.interpolationQuality = .high
        context.draw(source, in: tile)
        guard let image = context.makeImage() else { return Data() }
        let bitmap = NSBitmapImageRep(cgImage: image)
        return bitmap.representation(using: .png, properties: [:]) ?? Data()
    }
}
