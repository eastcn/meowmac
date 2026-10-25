import Foundation

/// Codex 宠物的 `pet.json`。只读需要的字段，其余字段忽略。
public struct CodexPetManifest: Equatable, Sendable {
    public let id: String
    public let displayName: String
    public let spritesheetPath: String
    public let version: Int

    public static let maxBytes = 65_536

    public init(id: String, displayName: String, spritesheetPath: String, version: Int) {
        self.id = id; self.displayName = displayName; self.spritesheetPath = spritesheetPath; self.version = version
    }

    /// 目录名的约束：不含路径分隔符，不以点开头。
    public static func isValidDirectoryName(_ name: String) -> Bool {
        guard (1...64).contains(name.count), let first = name.unicodeScalars.first, first != "." else { return false }
        return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }
            && name.allSatisfy(\.isASCII)
    }

    public static func parse(_ data: Data) throws -> CodexPetManifest {
        guard data.count <= maxBytes else { throw CodexPetError.invalid("pet.json 超过 64 KiB") }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw CodexPetError.invalid("pet.json 不是 JSON 对象")
        }
        guard let id = object["id"] as? String, !id.isEmpty, id.count <= 64 else { throw CodexPetError.invalid("缺少 id") }
        let rawName = (object["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let name = rawName.isEmpty ? id : String(rawName.prefix(40))
        guard !name.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else {
            throw CodexPetError.invalid("名称含控制字符")
        }
        guard let path = object["spritesheetPath"] as? String, !path.isEmpty else { throw CodexPetError.invalid("缺少 spritesheetPath") }
        guard path != ".", path != "..", !path.contains("/"), !path.contains("\\"), !path.hasPrefix(".") else {
            throw CodexPetError.invalid("spritesheetPath 必须是目录内的文件名")
        }
        let ext = (path as NSString).pathExtension.lowercased()
        guard ext == "png" || ext == "webp" else { throw CodexPetError.invalid("图集只支持 PNG 或 WebP") }
        let version: Int
        switch object["spriteVersionNumber"] {
        case nil: version = 1
        case let number as NSNumber where number.intValue == 1 || number.intValue == 2: version = number.intValue
        default: throw CodexPetError.invalid("spriteVersionNumber 只支持 1 或 2")
        }
        return CodexPetManifest(id: id, displayName: name, spritesheetPath: path, version: version)
    }
}

public enum CodexPetError: Error, LocalizedError, Equatable {
    case invalid(String)
    case missing
    public var errorDescription: String? {
        switch self {
        case .invalid(let reason): return reason
        case .missing: return "找不到这个宠物"
        }
    }
}

/// 图集的格子布局：每格 192×208，8 列；v1 有 9 行，v2 有 11 行（后两行是朝向，不用）。
public enum CodexPetAtlas {
    public static let columns = 8
    public static let cellWidth = 192
    public static let cellHeight = 208
    public static let maxBytes = 16 * 1024 * 1024

    public static func rows(version: Int) -> Int { version == 2 ? 11 : 9 }
    public static func size(version: Int) -> (width: Int, height: Int) {
        (columns * cellWidth, rows(version: version) * cellHeight)
    }
    /// 第 `row` 行第 `column` 列的格子，原点在图左上角。
    public static func cell(row: Int, column: Int) -> (x: Int, y: Int, width: Int, height: Int) {
        (column * cellWidth, row * cellHeight, cellWidth, cellHeight)
    }
}

/// 图集的标准动作行，顺序同 Codex 宠物合同。
public enum CodexPetRow: Int, CaseIterable, Sendable {
    case idle = 0, runningRight, runningLeft, waving, jumping, failed, waiting, running, review
}

/// 健康档位和负载决定播哪一行（plan P4）。
public enum CodexPetPose {
    /// 负载达到这个值时从坐改为跑。
    public static let runThreshold = 0.3

    public static func row(level: HealthLevel, load: Double) -> CodexPetRow {
        switch level {
        case .severe: return .failed
        case .warn: return .waiting
        case .normal: return load.isFinite && load >= runThreshold ? .runningRight : .idle
        }
    }

    /// 当前行要显示的格子序号。严重行只留一格，取最后一格并静止；减少动态效果或定格时取第 1 格。
    public static func frame(row: CodexPetRow, counter: Int, frameCount: Int, frozen: Bool) -> Int {
        guard frameCount > 0 else { return 0 }
        if row == .failed { return frameCount - 1 }
        if frozen { return 0 }
        return (counter % frameCount + frameCount) % frameCount
    }
}
