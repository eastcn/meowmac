import AppKit

/// 可见窗口验收由用户选择时机开启。过滤词或截图目录不会自动取得前台权限。
enum TestPresentationPolicy {
    static func allowsForeground(environment: [String: String]) -> Bool {
        environment["MEOWMAC_UI_TESTS"] == "1"
    }
    static let foregroundGroups = [
        "UI.NetworkSettings/", "UI.QuotaSettings/", "QuotaSettings.Live/",
        "UI.AppearanceSettings/", "UI.StyleSettings/", "UI.LayoutSettings/",
        "UI.AIDiagnosis/", "UI.AIAgentSettings/", "UI.AIAgent.Live/", "UI.Cleaning.Live/"
    ]
    static let foregroundCases: Set<String> = [
        "UI.QuotaAlertChannel/原生渠道开关与阈值保存", "Backlog.Network/真实入口展开收起与隐藏卡片",
        "UI.Settings/即时设置回调与条件", "UI.Settings/六栏合成窗口预览",
        "UI.SettingsWindow/单例定位与记忆", "UI.SettingsWindow/固定侧栏与移除切换按钮",
        "UI.Settings.AlertRules/真实数字框、启用和新建入口", "UI.Settings.AlertRules/合成真实窗口预览",
        "UI.Notifications/设置栏与提醒回调",
        "UI.Reminders/原生入口暂缓恢复与容器", "UI.Reminders/真实弹出面板与超高筛选",
        "UI.AIAgent/CLI 启动失败与复制入口", "UI.Cleaning/原生缺失状态容器",
        "UI.SystemTrend/真实弹出面板鼠标与首屏", "UI.Reset/真实360pt弹出容器与浅深色分节",
        "UI.QuotaSources/真实面板预览", "UI.PanelLayout/隐藏网络检查后点击总览告警",
        "UI.LayoutAcceptance/真实容器合成对照"
    ]
    static func requiresForeground(_ name: String) -> Bool {
        foregroundCases.contains(name) || foregroundGroups.contains { name.hasPrefix($0) }
    }
    static func regression() -> Bool {
        !allowsForeground(environment: [:])
            && !allowsForeground(environment: ["MEOWMAC_RENDER_DIR": "example", "MEOWMAC_LIVE": "1"])
            && !allowsForeground(environment: ["MEOWMAC_UI_TESTS": "0"])
            && allowsForeground(environment: ["MEOWMAC_UI_TESTS": "1"])
            && requiresForeground("UI.QuotaAlertChannel/原生渠道开关与阈值保存")
            && !requiresForeground("UI.QuotaAlertChannel/渠道开关阈值全局优先与恢复默认")
            && requiresForeground("Backlog.Network/真实入口展开收起与隐藏卡片")
            && !requiresForeground("Backlog.Network/失败域名与原因进入展示模型")
            && requiresForeground("UI.SettingsWindow/单例定位与记忆")
            && requiresForeground("UI.Reset/真实360pt弹出容器与浅深色分节")
            && !requiresForeground("UI.Reset/独立快照与四渠道归属")
            && !requiresForeground("UI.SettingsWindow/切栏与关闭三选确认")
    }
}
