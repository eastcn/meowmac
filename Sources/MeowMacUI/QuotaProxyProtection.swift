import Foundation
import MeowMacCore
import TunCanaryCore
import TunCanarySystem

/// 只决定 MeowMac 能否发起额度查询，不约束已经运行的 CLI。
public enum QuotaProxyStatus: Sendable, Equatable {
    case ready, checking, off, inactive, unknown, switching, stale

    public var reason: String? {
        switch self {
        case .ready: return nil
        case .checking: return "尚未确认 Clash 核心和 TUN 状态"
        case .off: return "Clash TUN 未开启"
        case .inactive: return "Clash 核心未运行或 TUN 接口未生效"
        case .unknown: return "无法确认 Clash 核心和 TUN 状态"
        case .switching: return "网络正在切换，等待重新确认 TUN"
        case .stale: return "TUN 检查结果已过期"
        }
    }
}

public enum QuotaProxyProtection {
    public static func protects(_ provider: QuotaProvider) -> Bool { provider == .codex || provider == .claude }

    public static func status(_ local: LocalAssessment?, at now: Date) -> QuotaProxyStatus {
        guard let local else { return .checking }
        if local.isInGracePeriod { return .switching }
        let age = now.timeIntervalSince(local.evaluatedAt)
        guard age >= 0, age <= 30 else { return .stale }
        switch local.tunState {
        case .running: return .ready
        case .off: return .off
        case .inactive: return .inactive
        case .unknown: return .unknown
        }
    }

    /// 复用检测引擎，只采集本机证据；不做 DNS、站点或出口请求。
    public static func localConfiguration(paths: KnownPaths, source: ProxySource) -> SystemSnapshotProvider.Configuration {
        SystemSnapshotProvider.Configuration(paths: paths, proxySource: { source },
            resolvesCanary: false, probesMihomoDNS: false, dnsGuardPaths: nil)
    }

    public static func check() async -> QuotaProxyStatus {
        let paths = KnownPaths.currentUser()
        let settings = SettingsStore().load()
        // 手动来源允许省略核心进程证据，不能用它放行此处的 Clash 保护。
        guard settings.proxySource.client == .clashVergeRev else { return .unknown }
        let provider = SystemSnapshotProvider(configuration: localConfiguration(paths: paths, source: settings.proxySource))
        let snapshot = await provider.collectSnapshot()
        let local = LocalEvaluator(paths: paths).evaluate(snapshot: snapshot, settings: settings, inGracePeriod: false)
        return status(local, at: Date())
    }
}

@MainActor
public extension PanelState {
    var quotaProxyWarning: String? {
        guard quotaProviders.contains(where: QuotaProxyProtection.protects), let reason = quotaProxyStatus.reason else { return nil }
        return reason + "，已暂停 GPT/Codex 和 Claude 额度查询。"
    }
    func quotaPauseMessage(_ provider: QuotaProvider) -> String? {
        guard QuotaProxyProtection.protects(provider), let reason = quotaProxyStatus.reason else { return nil }
        let last = quotas[provider].map { "最后成功：" + DisplayDate.format($0.updatedAt, pattern: "M/d HH:mm") }
        return "已暂停查询：" + reason + "。" + (last.map { $0 + "，当前显示缓存。" } ?? "尚无成功采集的数据。")
    }
}
