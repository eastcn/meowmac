import Foundation
import os
import MeowMacCore

/// 桌面猫的目录和数值只读面板已有的状态，口径与总览一致（D9）。
public extension PanelState {
    var desktopCatInputs: DesktopCatInputs {
        var inputs = DesktopCatInputs()
        inputs.snapshot = snapshot
        inputs.quotaProviders = quotaProviders
        inputs.quotas = quotas
        inputs.quotaBasis = style.quotaBasis
        inputs.balanceThresholds = Dictionary(uniqueKeysWithValues: quotaProviders.map { ($0, quotaSources.balanceThreshold($0)) })
        let costs = [QuotaProvider.claude, .codex].filter(quotaProviders.contains).compactMap { costDisplay($0) }
        inputs.costAvailable = !costs.isEmpty
        inputs.costToday = costs.isEmpty ? nil : costs.reduce(0) { $0 + $1.todayCost }
        if let model = networkModel {
            inputs.networkAvailable = true
            inputs.networkTone = networkTone
            inputs.networkCheckedAt = model.lastCheckedAt
            if networkTone == .yellow || networkTone == .red {
                let display = model.meowMacDisplay
                let worst = display.checks.first { $0.tone == .red } ?? display.checks.first { $0.tone == .yellow }
                inputs.networkReason = worst?.name ?? "站点"
            }
        }
        inputs.proxyEnabled = proxyTraffic.enabled
        if proxyTraffic.enabled && proxyTraffic.available {
            let summary = ProxyTrafficSummary(rows: proxyTraffic.rows, range: .today, now: now())
            inputs.proxyTodayBytes = summary.proxy.total
            inputs.proxyUpdatedAt = now()
        }
        inputs.agentSessions = agentSessions
        return inputs
    }
    /// 目录只在菜单和设置里用：这时才查一次会话记录根目录是否存在（只查目录，不读记录）。
    var desktopCatCatalog: [DesktopCatCatalogEntry] {
        var inputs = desktopCatInputs
        inputs.agentSessionsInstalled = agentSessionRootsExist()
        return DesktopCatCatalog.entries(inputs)
    }
    var desktopCatItems: [DesktopCatItem] { DesktopCatCatalog.items(selected: desktopCat.metrics, inputs: desktopCatInputs) }
}

public extension PanelState {
    /// 设置、右键菜单和底部设置菜单共用的即时写入：先只写 `desktopCat` 字段，成功后才更新界面（D6、D8）。
    @discardableResult
    func updateDesktopCat(_ change: (DesktopCatConfig) throws -> DesktopCatConfig) -> Bool {
        do {
            let next = try change(desktopCat).validated()
            guard next != desktopCat else { desktopCatError = nil; return true }
            try ConfigStore.saveDesktopCat(next, to: desktopCatConfigURL)
            desktopCat = next
            desktopCatError = nil
            onDesktopCatChanged(next)
            return true
        } catch let error as DesktopCatError {
            desktopCatError = error.localizedDescription
            return false
        } catch {
            desktopCatError = "保存失败，配置文件未改动"
            Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "desktop-cat").error("桌面猫配置保存失败：\(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}

public extension PanelState {
    /// 桌面猫大小的即时写入（plan D16）：夹取并吸附后只写 `desktopCat.catHeight`，写入成功后才生效。
    @discardableResult
    func updateDesktopCatHeight(_ height: Double) -> Bool {
        let next = Double(DesktopCatSize.resolved(CGFloat(height)))
        guard next != desktopCat.catHeight else { desktopCatError = nil; return true }
        do {
            try ConfigStore.saveDesktopCatHeight(next, fallback: desktopCat, to: desktopCatConfigURL)
            desktopCat = desktopCat.with(catHeight: next)
            desktopCatError = nil
            onDesktopCatChanged(desktopCat)
            return true
        } catch let error as DesktopCatError {
            desktopCatError = error.localizedDescription
            return false
        } catch {
            desktopCatError = "保存失败，配置文件未改动"
            Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "desktop-cat").error("桌面猫大小保存失败：\(error.localizedDescription, privacy: .private)")
            return false
        }
    }
}
