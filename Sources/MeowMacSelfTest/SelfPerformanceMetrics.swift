import Foundation
import Darwin

/// 所有时间用单调时钟；CPU 100% 表示占满一个核心。
struct PerformanceReading: Codable {
    let pid: Int32
    let identity: UInt64
    let uptime: Double
    let userNS: UInt64
    let systemNS: UInt64
    let packageIdleWakeups: UInt64
    let interruptWakeups: UInt64
    let residentBytes: UInt64
    let footprintBytes: UInt64

    /// `ri_user_time` 和 `ri_system_time` 是 mach 绝对时间刻度，不是纳秒。
    /// Apple Silicon 的 timebase 是 125/3，Intel 是 1/1。
    static let timebase: (numer: UInt32, denom: UInt32) = {
        var info = mach_timebase_info_data_t()
        guard mach_timebase_info(&info) == KERN_SUCCESS, info.numer > 0, info.denom > 0 else { return (1, 1) }
        return (info.numer, info.denom)
    }()
    static func nanoseconds(_ ticks: UInt64, timebase: (numer: UInt32, denom: UInt32)) -> UInt64 {
        let product = ticks.multipliedFullWidth(by: UInt64(timebase.numer))
        guard product.high < UInt64(timebase.denom) else { return UInt64.max }
        return UInt64(timebase.denom).dividingFullWidth(product).quotient
    }
    static func read(_ pid: Int32) throws -> Self {
        var value = rusage_info_v6()
        let code = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, Int32(RUSAGE_INFO_V6), $0)
            }
        }
        guard code == 0 else { throw PerformanceError.invalid("proc_pid_rusage pid=\(pid) errno=\(errno)") }
        return Self(pid: pid, identity: value.ri_proc_start_abstime, uptime: ProcessInfo.processInfo.systemUptime,
            userNS: nanoseconds(value.ri_user_time, timebase: timebase),
            systemNS: nanoseconds(value.ri_system_time, timebase: timebase),
            packageIdleWakeups: value.ri_pkg_idle_wkups, interruptWakeups: value.ri_interrupt_wkups,
            residentBytes: value.ri_resident_size, footprintBytes: value.ri_phys_footprint)
    }
    func delta(to end: Self) throws -> PerformanceDelta {
        guard pid == end.pid, identity == end.identity, identity > 0,
              end.uptime.isFinite, uptime.isFinite, end.uptime > uptime,
              end.userNS >= userNS, end.systemNS >= systemNS,
              end.packageIdleWakeups >= packageIdleWakeups, end.interruptWakeups >= interruptWakeups else {
            throw PerformanceError.invalid("PID 重启、计数倒退或时间无效")
        }
        let cpuSeconds = Double(end.userNS - userNS) / 1e9 + Double(end.systemNS - systemNS) / 1e9
        return PerformanceDelta(elapsed: end.uptime - uptime, cpuSeconds: cpuSeconds,
            cpuPercent: cpuSeconds / (end.uptime - uptime) * 100,
            ri_pkg_idle_wkups: end.packageIdleWakeups - packageIdleWakeups,
            ri_interrupt_wkups: end.interruptWakeups - interruptWakeups,
            residentBytes: end.residentBytes, footprintBytes: end.footprintBytes)
    }
}
struct PerformanceDelta: Codable {
    let elapsed: Double
    let cpuSeconds: Double
    let cpuPercent: Double
    let ri_pkg_idle_wkups: UInt64
    let ri_interrupt_wkups: UInt64
    let residentBytes: UInt64
    let footprintBytes: UInt64
}
enum PerformanceError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String { switch self { case .invalid(let reason): return reason } }
}

enum SelfPerformanceMetricsTests {
    static func comparator() -> Bool {
        do {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["python3", "scripts/self-performance.py", "selftest"]
            process.standardOutput = Pipe(); process.standardError = Pipe()
            try process.run(); process.waitUntilExit()
            return process.terminationStatus == 0
        } catch { print("性能比较器未运行：\(error)"); return false }
    }
    static func timebase() -> Bool {
        // 伪造 timebase：125/3 时 24 个刻度是 1000 纳秒；1/1 时原样返回；中间乘积超过 64 位也不溢出。
        let silicon = (numer: UInt32(125), denom: UInt32(3)), identity = (numer: UInt32(1), denom: UInt32(1))
        let ticks: UInt64 = 24_000_000
        guard PerformanceReading.nanoseconds(24, timebase: silicon) == 1000,
              PerformanceReading.nanoseconds(ticks, timebase: silicon) == 1_000_000_000,
              PerformanceReading.nanoseconds(ticks, timebase: identity) == ticks,
              PerformanceReading.nanoseconds(3 << 56, timebase: silicon) == 125 << 56 else { return false }
        let start = PerformanceReading(pid: 42, identity: 10, uptime: 5, userNS: 0, systemNS: 0,
            packageIdleWakeups: 0, interruptWakeups: 0, residentBytes: 0, footprintBytes: 0)
        let end = PerformanceReading(pid: 42, identity: 10, uptime: 7,
            userNS: PerformanceReading.nanoseconds(ticks, timebase: silicon), systemNS: 0,
            packageIdleWakeups: 0, interruptWakeups: 0, residentBytes: 0, footprintBytes: 0)
        // 1 秒 CPU / 2 秒墙钟 = 50%；按刻度直接除 1e9 只会得到 1.2%。
        guard let delta = try? start.delta(to: end), abs(delta.cpuPercent - 50) < 1e-9 else { return false }
        let host = PerformanceReading.timebase
        return host.numer > 0 && host.denom > 0
    }
    static func readings() -> Bool {
        let start = PerformanceReading(pid: 42, identity: 10, uptime: 5, userNS: 100, systemNS: 100,
            packageIdleWakeups: 2, interruptWakeups: 3, residentBytes: 10, footprintBytes: 20)
        let good = PerformanceReading(pid: 42, identity: 10, uptime: 7, userNS: 1_000_000_100, systemNS: 100,
            packageIdleWakeups: 5, interruptWakeups: 7, residentBytes: 20, footprintBytes: 30)
        guard let delta = try? start.delta(to: good), delta.cpuPercent == 50, delta.ri_pkg_idle_wkups == 3,
              delta.ri_interrupt_wkups == 4, delta.footprintBytes == 30 else { return false }
        for invalid in [PerformanceReading(pid: 42, identity: 11, uptime: 7, userNS: 100, systemNS: 100, packageIdleWakeups: 2, interruptWakeups: 3, residentBytes: 0, footprintBytes: 0),
                        PerformanceReading(pid: 42, identity: 10, uptime: 5, userNS: 100, systemNS: 100, packageIdleWakeups: 2, interruptWakeups: 3, residentBytes: 0, footprintBytes: 0),
                        PerformanceReading(pid: 42, identity: 10, uptime: 7, userNS: 99, systemNS: 100, packageIdleWakeups: 2, interruptWakeups: 3, residentBytes: 0, footprintBytes: 0)] {
            if (try? start.delta(to: invalid)) != nil { return false }
        }
        // 缺少读数或坏类型必须拒绝，不能把不可用填成零。
        return (try? JSONDecoder().decode(PerformanceReading.self, from: Data("{}".utf8))) == nil
            && (try? JSONDecoder().decode(PerformanceReading.self, from: Data("{\"pid\":\"bad\"}".utf8))) == nil
    }
}
