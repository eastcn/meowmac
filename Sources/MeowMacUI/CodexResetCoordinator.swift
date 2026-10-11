import AppKit
import MeowMacQuota

@MainActor
public final class CodexResetCoordinator {
    private let state: PanelState
    private let client: CodexResetClient
    private var timer: Timer?
    private var task: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var sleeping = false
    private var running = false
    public init(state: PanelState, client: CodexResetClient? = nil) {
        self.state = state; self.client = client ?? CodexResetClient()
    }
    public func start() {
        guard !running else { return }
        running = true
        // 旧缓存只用于显示，不能确认上一轮提醒已经恢复。
        publish(confirmed: false)
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refresh() }
        }
        let center = NSWorkspace.shared.notificationCenter
        observers.append(center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setSleeping(true) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor [weak self] in self?.setSleeping(false) }
        })
        refresh()
    }
    public func refresh(manual: Bool = false) {
        guard running, !sleeping, task == nil else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let attempted = await self.client.refresh(manual: manual)
            if attempted { self.publish(confirmed: !Task.isCancelled) }
            self.task = nil
        }
    }
    public func setSleeping(_ value: Bool) {
        sleeping = value
        if value { task?.cancel() }
        else { refresh() }
    }
    private func publish(confirmed: Bool) {
        state.codexResetState = client.state
        if client.state.failures > 0 || (confirmed && client.state.hasResult) {
            state.failures["quota.codex-resets"] = client.state.failures
        }
    }
    public func stop() {
        running = false; timer?.invalidate(); timer = nil
        task?.cancel()
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers.removeAll()
    }
}
