import Foundation

/// 渠道仅覆盖内置额度规则；缺省继承全局规则，全局停用始终优先。
public struct QuotaAlertProviderOverride: Codable, Equatable {
    public var remainingEnabled: Bool?
    public var paceEnabled: Bool?
    public var balanceEnabled: Bool?
    public var remainingThreshold: Double?
    public init(remainingEnabled: Bool? = nil, paceEnabled: Bool? = nil, balanceEnabled: Bool? = nil, remainingThreshold: Double? = nil) {
        self.remainingEnabled = remainingEnabled; self.paceEnabled = paceEnabled
        self.balanceEnabled = balanceEnabled; self.remainingThreshold = remainingThreshold
    }
    public func enabled(_ rule: BuiltinAlertRule) -> Bool? {
        switch rule {
        case .quotaLow: return remainingEnabled
        case .pace: return paceEnabled
        case .balance: return balanceEnabled
        default: return nil
        }
    }
    public mutating func setEnabled(_ rule: BuiltinAlertRule, _ enabled: Bool) {
        // 开启即回到默认继承；全局开关仍可停用所有渠道。
        let value: Bool? = enabled ? nil : false
        switch rule {
        case .quotaLow: remainingEnabled = value
        case .pace: paceEnabled = value
        case .balance: balanceEnabled = value
        default: break
        }
    }
}
