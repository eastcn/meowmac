import SwiftUI
import MeowMacCore

public enum SnoozeUnit: String, CaseIterable {
    case minutes = "分钟", hours = "小时", days = "天"
    public var seconds: Double { switch self { case .minutes: return 60; case .hours: return 3600; case .days: return 86400 } }
    public func duration(_ text: String) -> TimeInterval? {
        guard !text.isEmpty, text.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(text), value > 0 else { return nil }
        let seconds = Double(value) * self.seconds
        return seconds >= 60 && seconds <= 30 * 86400 ? seconds : nil
    }
}

struct ReminderHeader: View {
    @ObservedObject var state: PanelState
    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            HStack {
                Button { state.showingReminders = false; state.activeSnoozeID = nil } label: { Label("返回", systemImage: "chevron.left") }
                    .buttonStyle(.plain).font(Design.button)
                Spacer()
                Text("全部提醒 · \(state.allReminders.count) 项").font(Design.title)
            }
            CapsuleSelector(titles: ["全部", "系统", "额度", "网络"], selected: state.reminderFilter.map { PanelTab.allCases.firstIndex(of: $0)! + 1 } ?? 0) { index in
                state.reminderFilter = index == 0 ? nil : PanelTab.allCases[index - 1]
            }
        }.padding(Design.inset)
    }
}

struct ReminderList: View {
    @ObservedObject var state: PanelState
    private var filtered: [Reminder] { state.allReminders.filter { state.reminderFilter == nil || $0.tab == state.reminderFilter } }
    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            if filtered.isEmpty {
                Text("当前没有提醒").font(Design.title)
                Text("新的问题会在这里显示。").font(Design.body).foregroundStyle(Design.secondary)
            }
            group("待关注", rows: filtered.filter { $0.level > .normal && state.snoozeDeadline($0) == nil })
            group("已知晓", rows: filtered.filter { state.snoozeDeadline($0) != nil })
            group("提示", rows: filtered.filter { $0.level == .normal })
        }.padding(Design.inset)
    }
    @ViewBuilder private func group(_ title: String, rows: [Reminder]) -> some View {
        if !rows.isEmpty {
            Text("\(title) · \(rows.count)").font(Design.title).foregroundStyle(Design.secondary)
            ForEach(rows) { reminder in ReminderRow(state: state, reminder: reminder) }
        }
    }
}

private struct ReminderRow: View {
    @ObservedObject var state: PanelState
    let reminder: Reminder
    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: Design.gap) {
                HStack(alignment: .top, spacing: Design.rowGap) {
                    Circle().fill(Design.state(reminder.level)).frame(width: Design.dot, height: Design.dot).padding(.top, 5)
                    Text(reminder.title).font(Design.title).fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text(reminder.level == .severe ? "严重" : reminder.tab.title).font(Design.tiny)
                        .foregroundStyle(Design.stateText(reminder.level)).padding(.horizontal, 3).padding(.vertical, 1)
                        .overlay(RoundedRectangle(cornerRadius: 5).stroke(Design.state(reminder.level)))
                }
                if !reminder.detail.isEmpty { Text(reminder.detail).font(Design.body).fixedSize(horizontal: false, vertical: true) }
                Text(state.reminderDataTime(reminder))
                    .font(Design.caption).foregroundStyle(Design.secondary)
                if let end = state.snoozeDeadline(reminder) {
                    Text("暂缓至 " + DisplayDate.format(end, pattern: "M 月 d 日 HH:mm")).font(Design.caption).foregroundStyle(Design.secondary)
                } else if !reminder.canSnooze && reminder.level > .normal {
                    Text("需要持续关注，检测恢复后消除").font(Design.caption).foregroundStyle(Design.secondary)
                }
                HStack {
                    if state.showsAIDiagnosis(for: reminder) { AIDiagnosisEntry(state: state, id: "reminder.ai." + reminder.id) }
                    Button("查看详情") { state.showReminderDetail(reminder) }.accessibilityIdentifier("reminder.detail.\(reminder.id)")
                    Spacer(minLength: 0)
                    if state.snoozeDeadline(reminder) != nil {
                        Button("恢复提醒") {
                            do { try state.restoreReminder(reminder.id) }
                            catch { state.reminderError = "恢复提醒未保存：" + error.localizedDescription }
                        }.accessibilityIdentifier("reminder.restore.\(reminder.id)")
                    } else if reminder.canSnooze {
                        Button("我已知道…") { state.activeSnoozeID = reminder.id }.accessibilityIdentifier("reminder.snooze.\(reminder.id)")
                    }
                }.buttonStyle(.plain).font(Design.button).foregroundStyle(Design.blue)
            }.padding(.vertical, Design.sectionGap)
            SectionRule()
        }
    }
}

struct SnoozeForm: View {
    @ObservedObject var state: PanelState
    let reminder: Reminder
    @State private var preset: Double? = 3600
    @State private var custom = "1"
    @State private var unit: SnoozeUnit = .hours
    @State private var untilReset = false
    @State private var error: String?
    private let presets: [(String, Double)] = [("30 分钟", 1800), ("1 小时", 3600), ("4 小时", 14400), ("1 天", 86400), ("2 天", 172800), ("3 天", 259200)]
    private var reliableReset: Date? {
        guard reminder.confirmed, reminder.isCycleReminder, let reset = reminder.resetAt,
              reset.timeIntervalSince(state.now()) >= 60 else { return nil }; return reset
    }
    private var seconds: Double? { preset ?? unit.duration(custom) }
    private var end: Date? { untilReset ? reliableReset : seconds.map { state.now().addingTimeInterval($0) } }
    var body: some View {
        VStack(alignment: .leading, spacing: Design.sectionGap) {
            Text(reminder.title).font(Design.title).fixedSize(horizontal: false, vertical: true)
            Text("选择本次暂缓时长").font(Design.body)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())], spacing: Design.rowGap) {
                ForEach(presets, id: \.1) { title, duration in
                    choice(title, selected: !untilReset && preset == duration) { preset = duration; untilReset = false }
                }
            }
            choice("自定义", selected: !untilReset && preset == nil) { preset = nil; untilReset = false }
            HStack {
                TextField("整数", text: $custom).textFieldStyle(.roundedBorder).frame(width: 100)
                    .onChange(of: custom) { _, _ in preset = nil; untilReset = false }
                Picker("单位", selection: $unit) { ForEach(SnoozeUnit.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                    .labelsHidden().onChange(of: unit) { _, _ in preset = nil; untilReset = false }
            }
            if reliableReset != nil { choice("直到本轮重置", selected: untilReset) { untilReset = true } }
            Text(end.map { "将于 " + DisplayDate.format($0, pattern: "M 月 d 日 HH:mm") + " 再次提醒" } ?? "请输入 1 分钟至 30 天的整数时长")
                .font(Design.body).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
            Text("问题仍会显示在已知晓中；恢复后重现、额度新周期或严重升级会立即重新提醒。")
                .font(Design.caption).foregroundStyle(Design.secondary).fixedSize(horizontal: false, vertical: true)
            if let error { Text(error).font(Design.caption).foregroundStyle(Design.stateText(.warn)).fixedSize(horizontal: false, vertical: true) }
            HStack {
                Button("取消") { state.activeSnoozeID = nil }.keyboardShortcut(.cancelAction).accessibilityIdentifier("reminder.cancel")
                Spacer()
                Button("暂缓提醒") {
                    do { try state.snooze(reminder.id, seconds: seconds, untilReset: untilReset) }
                    catch { self.error = "暂缓未保存：" + error.localizedDescription }
                }.disabled(end == nil).keyboardShortcut(.defaultAction).accessibilityIdentifier("reminder.confirm")
            }.font(Design.button)
        }.padding(Design.inset)
    }
    private func choice(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Design.button).frame(maxWidth: .infinity).padding(.vertical, Design.rowGap)
                .background(selected ? Design.blue.opacity(0.15) : Design.track, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(selected ? Design.blue : Design.separator))
        }.buttonStyle(.plain)
    }
}
