import Foundation
import Darwin
import IOKit
import MeowMacCore

public final class SystemCollector {
    private var previousCPU: CPUTicks?
    private var previousNetwork: (counters: ByteCounters, time: Date)?

    public init() {}

    public func sample(at now: Date = Date()) -> SystemSnapshot {
        let ticks = Self.cpuTicks()
        let cpu = previousCPU.flatMap { old in ticks.flatMap { CPUTicks.usage(previous: old, current: $0) } }
        previousCPU = ticks

        let counters = Self.networkCounters()
        var rates: (received: Double, sent: Double)?
        if let previousNetwork, let counters {
            rates = ByteCounters.rates(previous: previousNetwork.counters, current: counters,
                                       seconds: now.timeIntervalSince(previousNetwork.time))
        }
        if let counters { previousNetwork = (counters, now) }

        let disk = Self.diskCapacity()
        let memory = Self.memoryUsage()
        return SystemSnapshot(timestamp: now, cpuUsage: cpu, memoryPressure: Self.memoryPressure(),
                              swapUsedBytes: Self.swapUsedBytes(), diskAvailableBytes: disk.available,
                              diskTotalBytes: disk.total, networkReceivedBytesPerSecond: rates?.received,
                              networkSentBytesPerSecond: rates?.sent, battery: Self.batteryMetrics(),
                              thermal: Self.thermalLevel(), memoryUsedBytes: memory.used, memoryTotalBytes: memory.total,
                              memoryPressurePercent: Self.memoryPressurePercent())
    }

    public static func cpuTicks() -> CPUTicks? {
        var cpuInfo: processor_info_array_t?
        var count: mach_msg_type_number_t = 0
        var cpuCount: natural_t = 0
        let status = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &cpuCount, &cpuInfo, &count)
        guard status == KERN_SUCCESS, let cpuInfo else { return nil }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), vm_size_t(count) * vm_size_t(MemoryLayout<integer_t>.size)) }
        var user: UInt64 = 0, system: UInt64 = 0, idle: UInt64 = 0, nice: UInt64 = 0
        for index in 0..<Int(cpuCount) {
            let offset = index * Int(CPU_STATE_MAX)
            user += UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_USER)]))
            system += UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_SYSTEM)]))
            idle += UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_IDLE)]))
            nice += UInt64(UInt32(bitPattern: cpuInfo[offset + Int(CPU_STATE_NICE)]))
        }
        return CPUTicks(user: user, system: system, idle: idle, nice: nice)
    }

    public static func memoryUsage() -> (used: UInt64?, total: UInt64) {
        var statistics = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &statistics) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        let total = ProcessInfo.processInfo.physicalMemory
        guard status == KERN_SUCCESS else { return (nil, total) }
        return (Self.usedMemoryBytes(statistics, pageSize: UInt64(vm_kernel_page_size)), total)
    }

    /// 活动监视器口径：App 内存、联动内存和被压缩，不含文件缓存。
    public static func usedMemoryBytes(_ statistics: vm_statistics64, pageSize: UInt64) -> UInt64 {
        let internalPages = UInt64(statistics.internal_page_count)
        let purgeable = UInt64(statistics.purgeable_count)
        let app = internalPages - min(internalPages, purgeable)
        return (app + UInt64(statistics.wire_count) + UInt64(statistics.compressor_page_count)) * pageSize
    }

    public static func pressurePercent(availableLevel: Int32?) -> Double? {
        availableLevel.map { min(100, max(0, 100 - Double($0))) }
    }

    public static func memoryPressurePercent() -> Double? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_level", &level, &size, nil, 0) == 0 else { return nil }
        return pressurePercent(availableLevel: level)
    }

    public static func memoryPressure() -> MemoryPressure {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return .unavailable }
        switch level {
        case 1: return .normal
        case 2: return .warn
        case 4: return .critical
        default: return .unavailable
        }
    }

    public static func swapUsedBytes() -> UInt64? {
        var swap = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &swap, &size, nil, 0) == 0 else { return nil }
        return swap.xsu_used
    }

    public static func diskCapacity() -> (available: Int64?, total: Int64?) {
        var value = statfs()
        guard statfs("/", &value) == 0 else { return (nil, nil) }
        return (Int64(value.f_bavail) * Int64(value.f_bsize), Int64(value.f_blocks) * Int64(value.f_bsize))
    }

    public static func networkCounters() -> ByteCounters? {
        var list: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&list) == 0, let list else { return nil }
        defer { freeifaddrs(list) }
        var received: UInt64 = 0, sent: UInt64 = 0
        var current: UnsafeMutablePointer<ifaddrs>? = list
        while let item = current {
            let value = item.pointee
            if let address = value.ifa_addr, address.pointee.sa_family == UInt8(AF_LINK),
               String(cString: value.ifa_name) != "lo0", let data = value.ifa_data {
                let counters = data.assumingMemoryBound(to: if_data.self).pointee
                received += UInt64(counters.ifi_ibytes)
                sent += UInt64(counters.ifi_obytes)
            }
            current = value.ifa_next
        }
        return ByteCounters(received: received, sent: sent)
    }

    public static func batteryMetrics() -> BatteryMetrics {
        let matching = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard service != 0 else { return BatteryMetrics(temperatureCelsius: nil, systemPowerWatts: nil) }
        defer { IOObjectRelease(service) }
        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any] else {
            return BatteryMetrics(temperatureCelsius: nil, systemPowerWatts: nil)
        }
        let telemetry = properties["PowerTelemetryData"] as? [String: Any]
        return BatteryMetrics.parse(temperature: properties["Temperature"] as? Int,
                                    systemLoad: telemetry?["SystemLoad"] as? Int)
    }

    public static func thermalLevel() -> ThermalLevel {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .unavailable
        }
    }
}
