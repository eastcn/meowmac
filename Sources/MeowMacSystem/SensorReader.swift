import Foundation
import IOKit
import MeowMacCore

/// 与 SMC 用户客户端交换的结构，C 侧为 80 字节。
/// Swift 不给内嵌元组补尾部填充，所以 `keyInfo` 后面手动补 3 字节。
private struct SMCKeyData {
    var key: UInt32 = 0
    var vers: (UInt8, UInt8, UInt8, UInt8, UInt16) = (0, 0, 0, 0, 0)
    var pLimit: (UInt16, UInt16, UInt32, UInt32, UInt32) = (0, 0, 0, 0, 0)
    var keyInfo: (dataSize: UInt32, dataType: UInt32, attributes: UInt8) = (0, 0, 0)
    var padding: (UInt8, UInt8, UInt8) = (0, 0, 0)
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)
        = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

/// 只读 SMC。只调用读键、读键信息和按序号取键三个命令，不写任何键。
final class SMCReader {
    struct KeyInfo { let size: UInt32; let type: String }
    private enum Command: UInt8 { case readBytes = 5, readIndex = 8, readInfo = 9 }
    private static let kernelIndex: UInt32 = 2
    static var layoutIsValid: Bool { MemoryLayout<SMCKeyData>.stride == 80 }

    private var connection: io_connect_t = 0
    private var infoCache: [UInt32: KeyInfo] = [:]

    deinit { close() }

    func open() -> Bool {
        if connection != 0 { return true }
        guard Self.layoutIsValid else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var opened: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, 0, &opened) == KERN_SUCCESS else { return false }
        connection = opened
        return true
    }

    func close() {
        if connection != 0 { IOServiceClose(connection) }
        connection = 0
        infoCache = [:]
    }

    private func call(_ input: inout SMCKeyData) -> SMCKeyData? {
        var output = SMCKeyData()
        var size = MemoryLayout<SMCKeyData>.stride
        let status = IOConnectCallStructMethod(connection, Self.kernelIndex, &input, MemoryLayout<SMCKeyData>.stride, &output, &size)
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    func info(_ key: UInt32) -> KeyInfo? {
        if let cached = infoCache[key] { return cached }
        var input = SMCKeyData(); input.key = key; input.data8 = Command.readInfo.rawValue
        guard let output = call(&input) else { return nil }
        let info = KeyInfo(size: output.keyInfo.dataSize, type: SMCDecoder.string(output.keyInfo.dataType))
        infoCache[key] = info
        return info
    }

    func read(_ key: UInt32) -> Double? {
        guard let info = info(key), info.size > 0, info.size <= 32 else { return nil }
        var input = SMCKeyData(); input.key = key; input.keyInfo.dataSize = info.size; input.data8 = Command.readBytes.rawValue
        guard let output = call(&input) else { return nil }
        let bytes = withUnsafeBytes(of: output.bytes) { Array($0.prefix(Int(info.size))) }
        return SMCDecoder.value(type: info.type, bytes: bytes)
    }

    func read(_ key: String) -> Double? { read(SMCDecoder.fourCC(key)) }

    /// 按序号枚举全部键名。
    func allKeys() -> [String]? {
        guard let count = read("#KEY"), count > 0, count < 100_000 else { return nil }
        var keys: [String] = []
        for index in 0..<UInt32(count) {
            var input = SMCKeyData(); input.data8 = Command.readIndex.rawValue; input.data32 = index
            if let output = call(&input) { keys.append(SMCDecoder.string(output.key)) }
        }
        return keys
    }
}

/// IOHID 事件系统里的温度传感器。符号不在公开头文件里，用 `dlsym` 取得；取不到就不可用。
final class HIDTemperatureReader {
    private typealias CreateClient = @convention(c) (CFAllocator?) -> Unmanaged<AnyObject>?
    private typealias SetMatching = @convention(c) (AnyObject, CFDictionary) -> Int32
    private typealias CopyServices = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyProperty = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?
    private typealias CopyEvent = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias FloatValue = @convention(c) (AnyObject, Int32) -> Double
    private static let temperatureEvent: Int64 = 15

    private struct Symbols {
        let create: CreateClient, setMatching: SetMatching, copyServices: CopyServices
        let copyProperty: CopyProperty, copyEvent: CopyEvent, floatValue: FloatValue
    }
    private static let symbols: Symbols? = {
        guard let handle = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW) else { return nil }
        func load<T>(_ name: String, _ type: T.Type) -> T? { dlsym(handle, name).map { unsafeBitCast($0, to: type) } }
        guard let create = load("IOHIDEventSystemClientCreate", CreateClient.self),
              let setMatching = load("IOHIDEventSystemClientSetMatching", SetMatching.self),
              let copyServices = load("IOHIDEventSystemClientCopyServices", CopyServices.self),
              let copyProperty = load("IOHIDServiceClientCopyProperty", CopyProperty.self),
              let copyEvent = load("IOHIDServiceClientCopyEvent", CopyEvent.self),
              let floatValue = load("IOHIDEventGetFloatValue", FloatValue.self) else { return nil }
        return Symbols(create: create, setMatching: setMatching, copyServices: copyServices,
                       copyProperty: copyProperty, copyEvent: copyEvent, floatValue: floatValue)
    }()

    private var client: AnyObject?

    func temperatures() -> [String: Double] {
        guard let symbols = Self.symbols else { return [:] }
        if client == nil {
            guard let created = symbols.create(kCFAllocatorDefault)?.takeRetainedValue() else { return [:] }
            _ = symbols.setMatching(created, ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5] as CFDictionary)
            client = created
        }
        guard let client, let services = symbols.copyServices(client)?.takeRetainedValue() as? [AnyObject] else { return [:] }
        var values: [String: Double] = [:]
        for service in services {
            guard let name = symbols.copyProperty(service, "Product" as CFString)?.takeRetainedValue() as? String,
                  let event = symbols.copyEvent(service, Self.temperatureEvent, 0, 0)?.takeRetainedValue() else { continue }
            values[name] = symbols.floatValue(event, Int32(Self.temperatureEvent << 16))
        }
        return values
    }
}

/// 采集实验传感器。首次采样枚举一次键清单，之后只读命中的键；读失败时下一次重新连接。
public final class SensorReader {
    private let smc = SMCReader()
    private let hid = HIDTemperatureReader()
    private var keys: (cpu: [String], gpu: [String])?

    public init() {}

    public func sample() -> SensorReadings {
        guard smc.open() else {
            return fallback(failure: "无法连接 SMC 传感器服务")
        }
        if keys == nil {
            guard let all = smc.allKeys() else {
                smc.close()
                return fallback(failure: "读不到 SMC 键清单")
            }
            keys = (all.filter(SensorAggregator.isCPUKey), all.filter(SensorAggregator.isGPUKey))
        }
        guard let keys else { return fallback(failure: "读不到 SMC 键清单") }
        var temperatures: [String: Double] = [:]
        for key in keys.cpu + keys.gpu {
            if let value = smc.read(key) { temperatures[key] = value }
        }
        let fanCount = smc.read("FNum").map { Int($0) }
        var fans: [(rpm: Double?, max: Double?)] = []
        for index in 0..<min(fanCount ?? 0, 8) {
            fans.append((smc.read("F\(index)Ac"), smc.read("F\(index)Mx")))
        }
        let cpuFound = temperatures.keys.contains(where: SensorAggregator.isCPUKey)
        let readings = SensorAggregator.make(smcTemperatures: temperatures, hidTemperatures: cpuFound ? [:] : hid.temperatures(),
                                             fanCount: fanCount, fans: fans)
        if temperatures.isEmpty && fanCount == nil {
            // 连接可能已失效，下次重新打开并重新枚举。
            smc.close(); self.keys = nil
        }
        return readings
    }

    private func fallback(failure: String) -> SensorReadings {
        SensorAggregator.make(smcTemperatures: [:], hidTemperatures: hid.temperatures(), fanCount: nil, fans: [], failure: failure)
    }
}
