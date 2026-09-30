public struct PanelTabLayout {
    public let tab: PanelTab
    public let title: String
    public let cardIDs: [String]

    public init(tab: PanelTab, title: String, cardIDs: [String]) {
        self.tab = tab; self.title = title; self.cardIDs = cardIDs
    }
}

public enum DefaultPanelLayout {
    public static let tabs = [
        PanelTabLayout(tab: .system, title: "系统", cardIDs: ["system.chart", "system.energy", "system.disk"]),
        PanelTabLayout(tab: .quota, title: "额度", cardIDs: ["quota.providers", "quota.cost"]),
        PanelTabLayout(tab: .network, title: "网络", cardIDs: ["network.monitor"]),
    ]

    public static func openingTab(summary: HealthSummary, lastViewed: PanelTab) -> PanelTab {
        summary.worst?.tab ?? lastViewed
    }
}
