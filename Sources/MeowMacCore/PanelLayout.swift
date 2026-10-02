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
        .network: [.init("network.checks", "连接检查"), .init("network.sites", "站点连通性"), .init("network.egress", "出口 IP")],
    ]
}

public struct PanelCardPlacement: Codable, Equatable {
    public var id: String
    public var visible: Bool
    public init(id: String, visible: Bool = true) { self.id = id; self.visible = visible }
}

public enum PanelLayoutError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        if case .invalid(let reason) = self { return "布局无效：\(reason)" }
        return nil
    }
}

public struct PanelLayout: Codable, Equatable {
    public var schemaVersion: Int = 1
    public var tabs: [PanelTab]
    public var cards: [String: [PanelCardPlacement]]

    public init(tabs: [PanelTab] = PanelTab.allCases, cards: [String: [PanelCardPlacement]]? = nil) {
        self.tabs = tabs
        self.cards = cards ?? Dictionary(uniqueKeysWithValues: PanelTab.allCases.map { tab in
            (tab.rawValue, (PanelLayoutCatalog.definitions[tab] ?? []).map { PanelCardPlacement(id: $0.id) })
        })
    }

    public static let `default` = PanelLayout()
    public func placements(for tab: PanelTab) -> [PanelCardPlacement] { cards[tab.rawValue] ?? [] }
    public func visibleIDs(for tab: PanelTab) -> [String] { placements(for: tab).filter(\.visible).map(\.id) }

    public func validated() throws -> PanelLayout {
        guard schemaVersion == 1, tabs.count == 3, Set(tabs) == Set(PanelTab.allCases),
              Set(cards.keys) == Set(PanelTab.allCases.map(\.rawValue)) else { throw PanelLayoutError.invalid("版本或标签页不完整") }
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
              Set(root.keys) == ["schemaVersion", "tabs", "cards"],
              let version = root["schemaVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue.isFinite,
              version.doubleValue == 1,
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
        return try PanelLayout(tabs: tabs, cards: cards).validated()
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
