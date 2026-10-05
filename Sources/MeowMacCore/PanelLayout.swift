import Foundation

public struct PanelCardDefinition {
    public let id: String
    public let title: String
    public let canHide: Bool
    public init(_ id: String, _ title: String, canHide: Bool = true) {
        self.id = id; self.title = title; self.canHide = canHide
    }
}

public enum PanelLayoutCatalog {
    public static let definitions: [PanelTab: [PanelCardDefinition]] = [
        .system: [.init("system.chart", "系统趋势", canHide: false), .init("system.energy", "能耗排行"), .init("system.disk", "磁盘")],
        .quota: [.init("quota.trend", "用量趋势"), .init("quota.cost", "花费"), .init("quota.storage", "本地存储")],
        .network: [.init("network.checks", "连接检查"), .init("network.sites", "站点延迟"),
                   .init("network.traffic", "上下行速率"), .init("network.egress", "出口 IP")],
    ]
}

public struct PanelCardPlacement: Codable, Equatable {
    public var id: String
    public var visible: Bool
    public init(id: String, visible: Bool = true) { self.id = id; self.visible = visible }
}

public enum OverviewItem: String, CaseIterable, Codable {
    case cpu, memory, quota, network
    public var title: String {
        switch self { case .cpu: return "CPU"; case .memory: return "内存"; case .quota: return "额度"; case .network: return "网络" }
    }
}

public struct OverviewQuota: Codable, Equatable {
    public var provider: QuotaProvider
    public var window: String
    public init(provider: QuotaProvider = .claude, window: String = "minutes:300") {
        self.provider = provider; self.window = window
    }
    public func selectedWindow(in snapshot: QuotaSnapshot?) -> QuotaWindow? {
        guard let windows = snapshot?.windows else { return nil }
        if window == "auto" { return windows.first }
        if window.hasPrefix("id:") { return windows.first { $0.identifier == String(window.dropFirst(3)) } }
        guard let minutes = Int(window.dropFirst(8)) else { return nil }
        let matches = windows.filter { $0.effectiveWindowMinutes == minutes }
        return matches.count == 1 ? matches.first : nil
    }
    public static func selector(for window: QuotaWindow, among windows: [QuotaWindow]) -> String {
        if let minutes = window.effectiveWindowMinutes,
           windows.filter({ $0.effectiveWindowMinutes == minutes }).count == 1 { return "minutes:\(minutes)" }
        return "id:" + window.identifier
    }
}

public struct PanelOverview: Codable, Equatable {
    public var order: [OverviewItem]
    public var hidden: [OverviewItem]
    public var quota: OverviewQuota
    public init(order: [OverviewItem] = OverviewItem.allCases, hidden: [OverviewItem] = [], quota: OverviewQuota = .init()) {
        self.order = order; self.hidden = hidden; self.quota = quota
    }
    public static let `default` = PanelOverview()
    public var visible: [OverviewItem] { order.filter { !hidden.contains($0) } }
    public func validated() throws {
        guard order.count == 4, Set(order) == Set(OverviewItem.allCases),
              hidden.count < 4, hidden.count == Set(hidden).count,
              Set(hidden).isSubset(of: Set(OverviewItem.allCases)) else { throw PanelLayoutError.invalid("总览格子不完整或全部隐藏") }
        let selector = quota.window
        if selector != "auto" {
            if selector.hasPrefix("minutes:") {
                let text = String(selector.dropFirst(8))
                guard let minutes = Int(text), minutes > 0, String(minutes) == text else { throw PanelLayoutError.invalid("额度窗口选择无效") }
            } else {
                guard selector.hasPrefix("id:"), selector.count > 3,
                      selector.count <= 131, selector.unicodeScalars.allSatisfy({ $0.value >= 32 && $0.value != 127 }) else {
                    throw PanelLayoutError.invalid("额度窗口选择无效")
                }
            }
        }
    }
}

public enum PanelLayoutError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let reason) = self { return "布局无效：\(reason)" }
        return nil
    }
}

public struct PanelLayout: Codable, Equatable {
    public var schemaVersion: Int = 2
    public var tabs: [PanelTab]
    public var cards: [String: [PanelCardPlacement]]
    public var overview: PanelOverview

    public init(tabs: [PanelTab] = PanelTab.allCases, cards: [String: [PanelCardPlacement]]? = nil,
                overview: PanelOverview = .default) {
        self.tabs = tabs
        self.overview = overview
        self.cards = cards ?? Dictionary(uniqueKeysWithValues: PanelTab.allCases.map { tab in
            (tab.rawValue, (PanelLayoutCatalog.definitions[tab] ?? []).map { PanelCardPlacement(id: $0.id) })
        })
    }

    public static let `default` = PanelLayout()
    public func placements(for tab: PanelTab) -> [PanelCardPlacement] { cards[tab.rawValue] ?? [] }
    public func visibleIDs(for tab: PanelTab) -> [String] { placements(for: tab).filter(\.visible).map(\.id) }

    public func validated() throws -> PanelLayout {
        guard schemaVersion == 2, tabs.count == 3, Set(tabs) == Set(PanelTab.allCases),
              Set(cards.keys) == Set(PanelTab.allCases.map(\.rawValue)) else { throw PanelLayoutError.invalid("版本或标签页不完整") }
        try overview.validated()
        for tab in PanelTab.allCases {
            let expected = PanelLayoutCatalog.definitions[tab] ?? []
            let placements = self.placements(for: tab)
            guard placements.count == expected.count, Set(placements.map(\.id)) == Set(expected.map(\.id)) else {
                throw PanelLayoutError.invalid("\(tab.rawValue) 功能块缺失、重复或跨页")
            }
            for definition in expected where !definition.canHide {
                guard placements.first(where: { $0.id == definition.id })?.visible == true else {
                    throw PanelLayoutError.invalid("\(definition.id) 必须常驻")
                }
            }
        }
        return self
    }

    public static func parse(_ data: Data) throws -> PanelLayout {
        func fail(_ text: String) -> PanelLayoutError { .invalid(text) }
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let version = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue.isFinite,
              [1.0, 2.0].contains(version.doubleValue),
              Set(root.keys) == (version.intValue == 1 ? Set(["schemaVersion", "tabs", "cards"]) : Set(["schemaVersion", "tabs", "cards", "overview"])),
              let tabNames = root["tabs"] as? [String],
              let cardRoot = root["cards"] as? [String: Any],
              Set(cardRoot.keys) == Set(PanelTab.allCases.map(\.rawValue)) else { throw fail("字段或类型错误") }
        let tabs = tabNames.compactMap(PanelTab.init(rawValue:))
        guard tabs.count == tabNames.count else { throw fail("标签页未知") }
        var cards: [String: [PanelCardPlacement]] = [:]
        for tab in PanelTab.allCases {
            guard let entries = cardRoot[tab.rawValue] as? [Any] else { throw fail("功能块数组错误") }
            cards[tab.rawValue] = try entries.map { entry in
                guard let object = entry as? [String: Any], Set(object.keys) == ["id", "visible"],
                      let id = object["id"] as? String,
                      let visible = object["visible"] as? NSNumber,
                      CFGetTypeID(visible) == CFBooleanGetTypeID() else { throw fail("功能块字段或类型错误") }
                return PanelCardPlacement(id: id, visible: visible.boolValue)
            }
        }
        var overview = PanelOverview.default
        if version.intValue == 2 {
            guard let object = root["overview"] as? [String: Any], Set(object.keys) == ["order", "hidden", "quota"],
                  let orderNames = object["order"] as? [String], let hiddenNames = object["hidden"] as? [String],
                  let quota = object["quota"] as? [String: Any], Set(quota.keys) == ["provider", "window"],
                  let providerName = quota["provider"] as? String, let provider = QuotaProvider(rawValue: providerName), QuotaCatalog.usageNames[provider.rawValue] != nil,
                  let selector = quota["window"] as? String,
                  orderNames.allSatisfy({ OverviewItem(rawValue: $0) != nil }),
                  hiddenNames.allSatisfy({ OverviewItem(rawValue: $0) != nil }) else { throw fail("总览字段或类型错误") }
            overview = PanelOverview(order: orderNames.compactMap(OverviewItem.init(rawValue:)),
                                     hidden: hiddenNames.compactMap(OverviewItem.init(rawValue:)),
                                     quota: OverviewQuota(provider: provider, window: selector))
        }
        return try PanelLayout(tabs: tabs, cards: migrated(cards), overview: overview).validated()
    }

    /// 已删除的功能块。v0.3 第 1 轮写入过 `system.sensors`，读取时去掉，其余顺序和显隐不变。
    static let removedCards: Set<String> = ["system.sensors"]
    static let addedNetworkCard = "network.traffic"

    static func migrated(_ cards: [String: [PanelCardPlacement]]) -> [String: [PanelCardPlacement]] {
        var result = cards
        result[PanelTab.system.rawValue] = cards[PanelTab.system.rawValue]?.filter { !removedCards.contains($0.id) }
        // 2026-10-04 新增 `network.traffic`。旧文件网络页恰好只缺这一块时，以可见状态插到站点之后（没有站点时插到出口之前）。
        if var network = cards[PanelTab.network.rawValue] {
            let ids = network.map(\.id), expected = (PanelLayoutCatalog.definitions[.network] ?? []).map(\.id)
            if !ids.contains(addedNetworkCard), ids.count == Set(ids).count, Set(ids + [addedNetworkCard]) == Set(expected) {
                let index = ids.firstIndex(of: "network.sites").map { $0 + 1 } ?? ids.firstIndex(of: "network.egress") ?? ids.count
                network.insert(PanelCardPlacement(id: addedNetworkCard), at: index)
                result[PanelTab.network.rawValue] = network
            }
        }
        return result
    }
}

public struct PanelTabLayout {
    public let tab: PanelTab
    public let title: String
    public let cardIDs: [String]
    public init(tab: PanelTab, title: String, cardIDs: [String]) {
        self.tab = tab; self.title = title; self.cardIDs = cardIDs
    }
}

public enum DefaultPanelLayout {
    public static let tabs = PanelTab.allCases.map { tab in
        PanelTabLayout(tab: tab, title: tab.title, cardIDs: PanelLayoutCatalog.definitions[tab]?.map(\.id) ?? [])
    }
    public static func openingTab(summary: HealthSummary, lastViewed: PanelTab) -> PanelTab {
        summary.worst?.tab ?? lastViewed
    }
}

public extension PanelTab {
    var title: String {
        switch self { case .system: return "系统"; case .quota: return "额度"; case .network: return "网络" }
    }
}
