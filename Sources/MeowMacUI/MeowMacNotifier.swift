import Foundation
import MeowMacCore
import TunCanaryCore
import TunCanaryUI
import UserNotifications
import os

/// MeowMac 的系统通知出口（D41）。
///
/// 同时实现 TunCanary 的 `UserNotifying`，注入给嵌入的检测引擎：权限申请照常转给系统，
/// TunCanary 自己的故障通知直接丢弃，网络故障改由 MeowMac 按提醒生成。
/// 只有运行在 `.app` 包内时才触碰 `UNUserNotificationCenter`，命令行和自测里全部为空操作。
@MainActor
public final class MeowMacNotifier: NSObject, UserNotifying, UNUserNotificationCenterDelegate {
    public let environment: AppBundleEnvironment
    /// 点通知时打开面板并跳到对应页，在主线程调用。
    public var onOpen: (PanelTab) -> Void = { _ in }
    private let logger = Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "notifications")

    public init(environment: AppBundleEnvironment = .current) {
        self.environment = environment
        super.init()
        // 系统只认一个代理；MeowMac 不再构造 TunCanary 的通知器，所以这里是唯一的代理。
        if isAvailable { UNUserNotificationCenter.current().delegate = self }
    }

    public var isAvailable: Bool { environment.isAppBundle }

    public func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    public func authorizationStatus() async -> NotificationAuthorization {
        guard isAvailable else { return .denied }
        return UserNotificationCenterNotifier.map(await UNUserNotificationCenter.current().notificationSettings().authorizationStatus)
    }

    /// TunCanary 的故障通知。D41：丢弃，由 MeowMac 按自己的提醒生成。
    public func deliver(_ notification: PendingNotification) async {}

    public func deliver(_ notice: SystemNotice, at date: Date = Date()) async {
        guard isAvailable else { return }
        do { try await UNUserNotificationCenter.current().add(Self.request(for: notice, at: date)) }
        catch { logger.error("系统通知发送失败：\(error.localizedDescription, privacy: .public)") }
    }

    public static func request(for notice: SystemNotice, at date: Date) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = NotificationContent.title
        content.subtitle = notice.subtitle
        content.body = notice.body
        content.threadIdentifier = "meowmac." + notice.tab.rawValue
        content.userInfo = ["tab": notice.tab.rawValue]
        if notice.sound { content.sound = .default }
        let identifier = "meowmac.\(notice.key).\(Int(date.timeIntervalSince1970))"
        return UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
    }

    /// 没有标签页信息的通知（例如升级前 TunCanary 发的）打开网络页。
    public nonisolated static func tab(for userInfo: [AnyHashable: Any]) -> PanelTab {
        (userInfo["tab"] as? String).flatMap(PanelTab.init(rawValue:)) ?? .network
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                                   withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .list, .sound])
    }

    public nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                                   withCompletionHandler completionHandler: @escaping () -> Void) {
        let tab = Self.tab(for: response.notification.request.content.userInfo)
        Task { @MainActor [weak self] in self?.onOpen(tab) }
        completionHandler()
    }
}

/// 把提醒变成通知：判定、写记录、发送（D41）。
@MainActor
public final class NotificationCoordinator {
    public private(set) var settings: NotificationSettings
    public private(set) var records: [String: NotifiedRecord]
    public private(set) var recoveryReason: String?
    private let store: NotificationStore
    private let send: (SystemNotice) -> Void
    private let startedAt: Date
    private let logger = Logger(subsystem: MeowMacCore.AppIdentity.bundleID, category: "notifications")

    public init(store: NotificationStore, startedAt: Date = Date(), send: @escaping (SystemNotice) -> Void) {
        self.store = store; self.send = send; self.startedAt = startedAt
        let loaded = store.load()
        settings = loaded.settings; records = loaded.records; recoveryReason = loaded.recoveryReason
    }

    /// 每次提醒 reconcile 之后调用。记录有变化才写盘。
    /// `batch` 是这一轮的检测结果：只有它确认过的键才算恢复，刚启动没有数据时不会把记录误判为恢复。
    public func process(_ tracker: ReminderTracker, batch: ReminderBatch?, now: Date, redact: (String) -> String = { $0 }) {
        let decision = NotificationDecider.decide(reminders: tracker.sorted(), isSnoozed: { tracker.isSnoozed($0, now: now) },
                                                  records: records, settings: settings, now: now,
                                                  confirmsRecovery: { key in
            guard let batch else { return true }
            guard let kind = key.split(separator: ".", maxSplits: 1).first.flatMap({ ReminderKind(rawValue: String($0)) }) else { return true }
            return batch.confirms(key, kind: kind)
        }, observingSince: startedAt)
        if decision.records != records {
            records = decision.records
            persist()
        }
        for notice in NotificationContent.notices(for: decision.reminders, now: now, redact: redact) { send(notice) }
    }

    /// TunCanary 的出口告警：IP 变化和地域超出范围发通知，地域恢复不发。
    /// IP 变化的告警不带地区，取该目标最新一条成功观测的地区；那条没有地区（查询失败或被限流）就不写，
    /// 不借用旧 IP 的地区。
    public func process(_ alert: EgressAlert, history: [EgressObservation] = [], redact: (String) -> String) {
        guard alert.kind != .regionRecovered, settings.allows(.egress) else { return }
        let latest = history.last { $0.result.target == alert.target && $0.result.isSuccess }
        let latestCountry = latest.flatMap { $0.geo?.ip == $0.result.ip ? $0.geo?.countryCode : nil }
        let place = (alert.countryCode ?? latestCountry).map(EgressRegions.name) ?? ""
        let body = redact("\(alert.target.displayName)（\(alert.target.host)）" + (place.isEmpty ? "" : "：" + place))
        let violation = alert.kind == .regionViolation
        send(SystemNotice(key: "egress." + (violation ? "region" : "ip"), tab: .network,
                          subtitle: violation ? "出口地域超出允许范围" : "出口 IP 已变化", body: body, sound: violation))
    }

    /// 保存失败时不改内存里的开关，返回 false。
    @discardableResult
    public func update(_ next: NotificationSettings) -> Bool {
        do {
            try store.save(settings: next, records: records)
            settings = next
            return true
        } catch {
            logger.error("通知设置保存失败：\(error.localizedDescription, privacy: .public)")
            return false
        }
    }

    private func persist() {
        do { try store.save(settings: settings, records: records) }
        catch { logger.error("通知记录保存失败：\(error.localizedDescription, privacy: .public)") }
    }
}
