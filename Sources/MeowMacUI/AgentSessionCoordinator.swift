import AppKit
import Foundation
import MeowMacCore
import MeowMacQuota
import os

/// AI 会话的读取节奏与结束提示（D46，plan D4、D7a）。
///
/// 只在桌面猫开着且选了“AI 会话”时运行：没有会话在跑每 60 秒检查一次，有会话在跑每 10 秒。
/// 只用一个可重设时间的计时器，下一次触发取“下一次检查”和“最早一条提示到期”中较早的一个。
/// 休眠和屏幕休眠时暂停，唤醒后立即检查一次。读取放在后台串行队列，结果回主线程更新 `PanelState`。
/// D8 的额度补刷（`QuotaCoordinator.sessionTimer`）不受影响，两者不共用计时器。
@MainActor
public final class AgentSessionCoordinator {
    private let state: PanelState
    private let read: @Sendable (Date) -> AgentSessionSnapshot
    private let queue = DispatchQueue(label: "io.github.eastcn.meowmac.agent-sessions", qos: .utility)
    private let logger = Logger(subsystem: AppIdentity.bundleID, category: "agent-sessions")
    public var now: () -> Date = { Date() }
    /// 是否应该运行；默认看桌面猫配置。
    public var wanted: () -> Bool
    /// 测试关掉它：不挂真实的计时器，只记下次触发时间。
    public var installsTimer = true

    public private(set) var timer: Timer?
    /// 下一次检查的间隔；nil 表示没在运行或暂停。
    public private(set) var interval: TimeInterval?
    public private(set) var nextFireAt: Date?
    /// 检查序号，每次检查完成加 1（D7a）。
    public private(set) var sequence = 0
    public private(set) var isRunning = false
    /// 测试打开它，记下每条日志的级别和文字。
    public var recordsLog = false
    public private(set) var logLines: [(level: String, text: String)] = []

    private var board: AgentSessionNoticeBoard?
    private var nextCheckAt: Date?
    private var inFlight = false
    private var generation = 0
    private var sleeping = false, screensSleeping = false
    private var lastNotice: String?
    private var observers: [NSObjectProtocol] = []

    public convenience init(state: PanelState, reader: AgentSessionReader = AgentSessionReader()) {
        self.init(state: state, read: { reader.read(now: $0) })
    }

    public init(state: PanelState, read: @escaping @Sendable (Date) -> AgentSessionSnapshot) {
        self.state = state; self.read = read
        wanted = { [weak state] in state.map { AgentSessionCadence.wanted($0.desktopCat) } ?? false }
        state.onDismissAgentSessionToast = { [weak self] ids in self?.dismiss(ids) }
    }

    public var paused: Bool { sleeping || screensSleeping }

    /// 按当前配置启动或停止。桌面猫配置变化时调用。
    public func apply() {
        if wanted() { start() } else { stop() }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        board = AgentSessionNoticeBoard(startedAt: now())
        let center = NSWorkspace.shared.notificationCenter
        let pairs: [(Notification.Name, Bool, Bool)] = [
            (NSWorkspace.willSleepNotification, true, true), (NSWorkspace.didWakeNotification, true, false),
            (NSWorkspace.screensDidSleepNotification, false, true), (NSWorkspace.screensDidWakeNotification, false, false),
        ]
        for (name, system, value) in pairs {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor [weak self] in
                    if system { self?.setSleeping(value) } else { self?.setScreensSleeping(value) }
                }
            })
        }
        checkSoon()
    }

    /// 关掉桌面猫或取消这项指标：立即停掉计时器，清空快照和提示。
    public func stop() {
        generation += 1
        isRunning = false
        board = nil
        inFlight = false
        nextCheckAt = nil
        cancelTimer()
        interval = nil
        lastNotice = nil
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
        if state.agentSessions != nil { state.agentSessions = nil }
        if !state.agentSessionToasts.isEmpty { state.agentSessionToasts = [] }
    }

    public func setSleeping(_ value: Bool) { setPause(system: value, screens: screensSleeping) }
    public func setScreensSleeping(_ value: Bool) { setPause(system: sleeping, screens: value) }

    private func setPause(system: Bool, screens: Bool) {
        let was = paused
        sleeping = system; screensSleeping = screens
        guard isRunning, was != paused else { return }
        if paused {
            nextCheckAt = nil; interval = nil; cancelTimer()
        } else {
            checkSoon()
        }
    }

    public func dismiss(_ ids: [String]) {
        guard var board else { return }
        board.dismiss(ids)
        self.board = board
        publishToasts()
        reschedule()
    }

    // MARK: - 检查

    private func checkSoon() {
        guard isRunning, !paused else { return }
        Task { @MainActor [weak self] in await self?.check() }
    }

    /// 立即检查一次。读取在后台串行队列；正在读时不重复发起。
    public func check() async {
        guard isRunning, !paused, !inFlight else { return }
        inFlight = true
        let token = generation
        let read = self.read
        let at = now()
        let snapshot: AgentSessionSnapshot = await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: read(at)) }
        }
        guard token == generation, isRunning else { return }
        inFlight = false
        apply(snapshot)
    }

    private func apply(_ snapshot: AgentSessionSnapshot) {
        let finished = now()
        sequence += 1
        state.agentSessions = snapshot
        if var board {
            board.update(snapshot.sessions, now: finished)
            self.board = board
            publishToasts()
        }
        let notice = AgentSessionLog.notice(snapshot)
        if notice != lastNotice {
            lastNotice = notice
            logger.notice("\(notice, privacy: .public)")
            if recordsLog { logLines.append(("notice", notice)) }
        }
        let line = AgentSessionLog.check(sequence: sequence, snapshot: snapshot, finishedAt: finished)
        logger.debug("\(line, privacy: .public)")
        if recordsLog { logLines.append(("debug", line)) }
        interval = AgentSessionCadence.interval(wanted: isRunning, paused: paused, running: snapshot.runningTotal)
        nextCheckAt = interval.map { finished.addingTimeInterval($0) }
        reschedule()
    }

    private func publishToasts() {
        let toasts = board?.toasts ?? []
        if toasts != state.agentSessionToasts { state.agentSessionToasts = toasts }
    }

    // MARK: - 计时器

    /// 只挂一个计时器：下一次检查和最早一条提示到期，取较早的一个。
    private func reschedule() {
        cancelTimer()
        guard isRunning, !paused else { return }
        let candidates = [nextCheckAt, board?.nextExpiry].compactMap { $0 }
        guard let fire = candidates.min() else { return }
        nextFireAt = fire
        guard installsTimer else { return }
        let timer = Timer(fire: fire, interval: 0, repeats: false) { [weak self] _ in
            Task { @MainActor [weak self] in await self?.fire() }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func cancelTimer() {
        timer?.invalidate(); timer = nil; nextFireAt = nil
    }

    /// 计时器到点：先清掉过期的提示，到了检查时间就检查。供测试模拟到点。
    public func fire() async {
        timer = nil
        guard isRunning, !paused else { return }
        let current = now()
        if var board, let expiry = board.nextExpiry, expiry <= current {
            board.expire(now: current)
            self.board = board
            publishToasts()
        }
        if let nextCheckAt, nextCheckAt <= current.addingTimeInterval(0.5) {
            await check()
        } else {
            reschedule()
        }
    }
}
