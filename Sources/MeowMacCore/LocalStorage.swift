import Foundation

public struct LocalStorageSnapshot: Codable {
    public let sampledAt: Date
    public let sessionsBytes: UInt64
    public let cacheBytes: UInt64
    public let otherBytes: UInt64
    public let sessionFileCount: Int
    public var totalBytes: UInt64 { sessionsBytes + cacheBytes + otherBytes }
    public init(sampledAt: Date, sessionsBytes: UInt64, cacheBytes: UInt64, otherBytes: UInt64, sessionFileCount: Int) {
        self.sampledAt = sampledAt; self.sessionsBytes = sessionsBytes; self.cacheBytes = cacheBytes
        self.otherBytes = otherBytes; self.sessionFileCount = sessionFileCount
    }
}
