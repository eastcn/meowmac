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

    static func read(_ pid: Int32) throws -> Self {
        var value = rusage_info_v6()
        let code = withUnsafeMutablePointer(to: &value) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(pid, Int32(RUSAGE_INFO_V6), $0)
            }
        }
        guard code == 0 else { throw PerformanceError.invalid("proc_pid_rusage pid=\(pid) errno=\(errno)") }
        return Self(pid: pid, identity: value.ri_proc_start_abstime, uptime: ProcessInfo.processInfo.systemUptime,
            userNS: value.ri_user_time, systemNS: value.ri_system_time,
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
