import Foundation

public enum CatPackageError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let reason): return "猫配置无效：\(reason)" }
    }
}

public struct CatRect: Equatable {
    public let x: Int, y: Int, width: Int, height: Int
    public init(_ values: [Int]) {
        x = values[0]; y = values[1]; width = values[2]; height = values[3]
    }
    public func fits(_ size: [Int]) -> Bool {
        x >= 0 && y >= 0 && width > 0 && height > 0 && x <= size[0] - width && y <= size[1] - height
    }
}

public struct CatFrame: Equatable {
    public let source: CatRect
    public let noseX: Int
}

public struct CatPackage: Equatable {
    public let id: String
    public let name: String
    public let runImage: String
    public let rendering: String
    public let runSize: [Int]
    public let canvas: [Int]
    public let noseAnchor: Int
    public let topPadding: Int
    public let frames: [CatFrame]
    public let severeImage: String
    public let severeSize: [Int]
    public let severeBounds: CatRect
    public let zzAnchorFraction: Double

    public static func parse(_ data: Data, builtin: Bool = false) throws -> CatPackage {
        func fail(_ reason: String) -> CatPackageError { .invalid(reason) }
        guard data.count <= 65_536 else { throw fail("清单超过 64 KiB") }
        func object(_ value: Any?, keys: Set<String>, label: String) throws -> [String: Any] {
            guard let dictionary = value as? [String: Any], Set(dictionary.keys) == keys else { throw fail("\(label)字段缺失或含未知字段") }
            return dictionary
        }
        func string(_ value: Any?, label: String) throws -> String {
            guard let string = value as? String else { throw fail("\(label)类型错误") }
            return string
        }
        func integer(_ value: Any?, label: String) throws -> Int {
            guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
                  number.doubleValue >= Double(Int.min), number.doubleValue < Double(Int.max) else { throw fail("\(label)必须是有限整数") }
            return number.intValue
        }
        func size(_ value: Any?, label: String) throws -> [Int] {
            guard let array = value as? [Any], array.count == 2 else { throw fail("\(label)须为二元尺寸") }
            let result = try array.map { try integer($0, label: label) }
            guard result.allSatisfy({ $0 > 0 }) else { throw fail("\(label)须为正数") }
            return result
        }
        func rect(_ value: Any?, label: String) throws -> CatRect {
            guard let array = value as? [Any], array.count == 4 else { throw fail("\(label)须为四元矩形") }
            return CatRect(try array.map { try integer($0, label: label) })
        }
        func filename(_ value: Any?, label: String) throws -> String {
            let name = try string(value, label: label)
            guard name.hasSuffix(".png"), name != ".png", !name.contains("/"), !name.contains("\\"),
                  name != ".", name != "..", !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
                throw fail("\(label)必须是包根目录中的 PNG 文件名")
            }
            return name
        }
        guard let raw = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else { throw fail("清单不是有效 JSON") }
        let root = try object(raw, keys: ["schemaVersion", "id", "name", "run", "severe"], label: "清单")
        guard try integer(root["schemaVersion"], label: "schemaVersion") == 1 else { throw fail("不支持的 schemaVersion") }
        let id = try string(root["id"], label: "id")
        let allowed = builtin ? "abcdefghijklmnopqrstuvwxyz0123456789._-" : "abcdefghijklmnopqrstuvwxyz0123456789._-"
        guard (1...64).contains(id.utf8.count), id.first.map({ "abcdefghijklmnopqrstuvwxyz0123456789".contains($0) }) == true,
              id.allSatisfy({ allowed.contains($0) }), builtin || !id.hasPrefix("builtin.") else { throw fail("id 格式无效或占用保留前缀") }
        let name = try string(root["name"], label: "name").trimmingCharacters(in: .whitespacesAndNewlines)
        guard (1...40).contains(name.count), !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw fail("名称须为 1～40 字且不能含控制字符") }
        let run = try object(root["run"], keys: ["image", "rendering", "sheetSize", "canvas", "noseAnchor", "topPadding", "frames"], label: "run")
        let runImage = try filename(run["image"], label: "run.image")
        let rendering = try string(run["rendering"], label: "rendering")
        guard rendering == "template" || rendering == "original" else { throw fail("rendering 只支持 template 或 original") }
        let runSize = try size(run["sheetSize"], label: "run.sheetSize")
        let canvas = try size(run["canvas"], label: "run.canvas")
        let noseAnchor = try integer(run["noseAnchor"], label: "noseAnchor")
        let topPadding = try integer(run["topPadding"], label: "topPadding")
        guard noseAnchor >= 0 && topPadding >= 0 else { throw fail("锚点和留白不能为负") }
        guard let rawFrames = run["frames"] as? [Any], rawFrames.count == 5 else { throw fail("跑步帧必须恰好为 5 帧") }
        let frames = try rawFrames.map { value -> CatFrame in
            let frame = try object(value, keys: ["source", "noseX"], label: "frame")
            return CatFrame(source: try rect(frame["source"], label: "source"), noseX: try integer(frame["noseX"], label: "noseX"))
        }
        for (index, frame) in frames.enumerated() {
            guard frame.source.fits(runSize), frame.noseX >= frame.source.x, frame.noseX <= frame.source.x + frame.source.width else { throw fail("第 \(index + 1) 帧越界或头部锚点无效") }
            guard frame.source.y == frames[0].source.y && frame.source.height == frames[0].source.height else { throw fail("跑步帧的纵向范围不一致") }
            if index > 0 { guard frames[index - 1].source.x + frames[index - 1].source.width <= frame.source.x else { throw fail("跑步帧横向重叠") } }
            let positionedX = Double(noseAnchor - (frame.noseX - frame.source.x))
            let scale = 17.0 / Double(canvas[1])
            let left = (50.0 - Double(canvas[0]) * scale) / 2 + positionedX * scale
            let right = left + Double(frame.source.width) * scale
            let bottom = (Double(topPadding) + Double(frame.source.height)) * scale
            guard left >= -0.000001 && right <= 50.000001 && bottom <= 18.000001 else { throw fail("第 \(index + 1) 帧超出 50×18 画布") }
        }
        let severe = try object(root["severe"], keys: ["image", "sheetSize", "bounds", "zzAnchorFraction"], label: "severe")
        let severeImage = try filename(severe["image"], label: "severe.image")
        let severeSize = try size(severe["sheetSize"], label: "severe.sheetSize")
        let severeBounds = try rect(severe["bounds"], label: "severe.bounds")
        guard severeBounds.fits(severeSize) else { throw fail("严重图范围越界") }
        guard let zzNumber = severe["zzAnchorFraction"] as? NSNumber, CFGetTypeID(zzNumber) != CFBooleanGetTypeID(),
              zzNumber.doubleValue.isFinite, (0...1).contains(zzNumber.doubleValue) else { throw fail("zzAnchorFraction 须在 0～1 之间") }
        return CatPackage(id: id, name: name, runImage: runImage, rendering: rendering, runSize: runSize,
                          canvas: canvas, noseAnchor: noseAnchor, topPadding: topPadding, frames: frames,
                          severeImage: severeImage, severeSize: severeSize, severeBounds: severeBounds, zzAnchorFraction: zzNumber.doubleValue)
    }
}
