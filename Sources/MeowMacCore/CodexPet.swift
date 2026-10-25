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

/// 菜单栏的形象（`config.json` 的 `menuBarPet`）。缺省与桌面猫相同；也可固定用当前猫或某只宠物。
public enum MenuBarPetConfig: Codable, Equatable, Sendable {
    /// 与桌面猫的“形象”相同：桌面猫选了宠物就用宠物，否则用当前猫。桌面猫关闭时同样跟随。
    case desktop
    case cat
    case pet(String)

    /// 菜单栏实际要用的宠物；nil 表示用当前猫。
    public func petID(desktop: String?) -> String? {
        switch self {
        case .desktop: return desktop
        case .cat: return nil
        case .pet(let id): return id
        }
    }

    private enum CodingKeys: String, CodingKey { case source, pet }

    /// 坏值抛错，由 `LocalConfig` 回退到 `.desktop` 并记诊断。
    public init(from decoder: Decoder) throws {
        let fields = try decoder.container(keyedBy: CodingKeys.self)
        switch try fields.decode(String.self, forKey: .source) {
        case "desktop": self = .desktop
        case "cat": self = .cat
        case "pet":
            let id = try fields.decode(String.self, forKey: .pet)
            guard CodexPetManifest.isValidDirectoryName(id) else { throw CodexPetError.invalid("宠物名无效") }
            self = .pet(id)
        default: throw CodexPetError.invalid("菜单栏形象无效")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var fields = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .desktop: try fields.encode("desktop", forKey: .source)
        case .cat: try fields.encode("cat", forKey: .source)
        case .pet(let id): try fields.encode("pet", forKey: .source); try fields.encode(id, forKey: .pet)
        }
    }

    public func validated() throws -> Self {
        if case .pet(let id) = self, !CodexPetManifest.isValidDirectoryName(id) { throw CodexPetError.invalid("宠物名无效") }
        return self
    }
}

public extension ConfigStore {
    /// 只写 `menuBarPet` 字段，保留其他字段和未知字段。
    static func saveMenuBarPet(_ config: MenuBarPetConfig, to url: URL = defaultURL) throws {
        let object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(config.validated()))
        try updateField("menuBarPet", value: object, at: url)
    }
}

/// 宠物动画速度（`config.json` 的 `petAnimationSpeed`）：宠物帧速度相对猫帧速度的倍数，仍随负载变化（D11）。
/// 默认 1.6：宠物跑一步 8 帧，猫 5 帧，1.6 倍时一步的时长与猫相同。
public enum PetAnimationSpeed {
    public static let defaultValue = 1.6
    public static let range = 0.5...3.0
    public static let step = 0.1
    /// 帧计时最短间隔，约 30 帧每秒。
    public static let minimumTick = 1.0 / 30

    public static func clamped(_ value: Double) -> Double {
        guard value.isFinite else { return defaultValue }
        return (min(range.upperBound, max(range.lowerBound, value)) / step).rounded() * step
    }

    public static func title(_ value: Double) -> String { String(format: "%.1f×", value) }
}

public extension ConfigStore {
    static func savePetAnimationSpeed(_ value: Double, to url: URL = defaultURL) throws {
        guard value.isFinite, PetAnimationSpeed.range.contains(value) else { throw CodexPetError.invalid("宠物动画速度无效") }
        try updateField("petAnimationSpeed", value: value, at: url)
    }
}

/// 猫和宠物共用一个帧计时器、各自计帧（不新增计时器）。按经过的时间累计，各自满一帧才前进。
public struct FrameClock: Equatable {
    public private(set) var cat = 0.0
    public private(set) var pet = 0.0
    public init() {}

    /// 下一次计时的间隔：没有宠物时同猫；有宠物时取两者较快的，不短于 `minimumTick`。
    public static func tick(frameInterval: Double, petSpeed: Double?) -> Double {
        guard let petSpeed, petSpeed > 1 else { return frameInterval }
        return max(frameInterval / petSpeed, PetAnimationSpeed.minimumTick)
    }

    /// 经过 `elapsed` 秒后，猫和宠物各前进几帧。
    public mutating func advance(elapsed: Double, frameInterval: Double, petSpeed: Double?) -> (cat: Int, pet: Int) {
        guard elapsed > 0, frameInterval > 0 else { return (0, 0) }
        let tolerance = 1e-6
        cat += elapsed / frameInterval
        pet += elapsed * (petSpeed ?? 1) / frameInterval
        let catSteps = Int((cat + tolerance).rounded(.down)), petSteps = Int((pet + tolerance).rounded(.down))
        cat = max(0, cat - Double(catSteps)); pet = max(0, pet - Double(petSteps))
        return (catSteps, petSteps)
    }
}
