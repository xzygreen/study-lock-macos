import AppKit
import Charts
import SwiftUI

private enum NavigationItem: String, CaseIterable, Identifiable {
    case focus
    case schedule
    case whitelist
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .focus: "专注"
        case .schedule: "定时"
        case .whitelist: "白名单"
        case .history: "记录"
        }
    }

    var symbol: String {
        switch self {
        case .focus: "timer"
        case .schedule: "calendar.badge.clock"
        case .whitelist: "checkmark.shield"
        case .history: "chart.bar"
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var engine: FocusEngine
    @State private var selection: NavigationItem = .focus
    @State private var showExitConfirmation = false

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Divider()
            content
        }
        .background(Color.appBackground)
        .overlay(alignment: .top) {
            VStack(spacing: 10) {
                if let notice = engine.taintNotice {
                    TaintNoticeBanner(notice: notice) {
                        engine.dismissTaintNotice()
                    }
                }
                if let issue = engine.hostsIssue {
                    HostsIssueBanner(issue: issue) {
                        engine.retryHostsSync()
                    }
                }
            }
            .padding(.top, 18)
            .padding(.horizontal, 24)
        }
        .overlay(alignment: .topTrailing) {
            if let appName = engine.blockedAppName {
                BlockedBanner(appName: appName)
                    .padding(.top, 22)
                    .padding(.trailing, 24)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: engine.blockedAppName)
        .animation(.easeOut(duration: 0.25), value: engine.taintNotice)
        .animation(.easeOut(duration: 0.25), value: engine.hostsIssue)
        .sheet(isPresented: $showExitConfirmation) {
            ExitConfirmationSheet()
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: "clock.badge.checkmark")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Color.brand)
                    .frame(width: 38, height: 38)
                    .background(Color.brand.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))

                VStack(alignment: .leading, spacing: 1) {
                    Text("认真")
                        .font(.system(size: 18, weight: .bold))
                    Text("STUDY LOCK")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 24)
            .padding(.bottom, 30)

            VStack(spacing: 6) {
                ForEach(NavigationItem.allCases) { item in
                    Button {
                        selection = item
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: item.symbol)
                                .font(.system(size: 15, weight: .medium))
                                .frame(width: 20)
                            Text(item.title)
                                .font(.system(size: 14, weight: .medium))
                            Spacer()
                        }
                        .foregroundStyle(selection == item ? Color.primary : Color.secondary)
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(
                            selection == item ? Color.white : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)

            Spacer()

            LockStatusPanel(showExitConfirmation: $showExitConfirmation)
                .padding(14)
        }
        .frame(width: 230)
        .background(Color.sidebarBackground)
    }

    @ViewBuilder
    private var content: some View {
        switch selection {
        case .focus:
            FocusView(showExitConfirmation: $showExitConfirmation)
        case .schedule:
            ScheduleView()
        case .whitelist:
            WhitelistView()
        case .history:
            HistoryView()
        }
    }
}

private struct LockStatusPanel: View {
    @EnvironmentObject private var engine: FocusEngine
    @Binding var showExitConfirmation: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Circle()
                    .fill(engine.isLockEnabled ? Color.danger : Color.success)
                    .frame(width: 8, height: 8)
                Text(engine.isLockEnabled ? "锁定中" : "未锁定")
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: engine.isLockEnabled ? "lock.fill" : "lock.open")
                    .foregroundStyle(.secondary)
            }

            if !engine.isSessionActive {
                Toggle(
                    "手动锁定",
                    isOn: Binding(
                        get: { engine.isManualLockOn },
                        set: { newValue in
                            if newValue {
                                engine.setManualLock(true)
                            } else {
                                // 关闭需过冷静期并输入确认短语
                                showExitConfirmation = true
                            }
                        }
                    )
                )
                .font(.system(size: 12))
                .toggleStyle(.switch)
                .controlSize(.small)
            } else {
                Text(engine.primaryTimeText)
                    .font(.system(size: 20, weight: .semibold, design: .monospaced))
                    .foregroundStyle(engine.isInPomodoroRest ? Color.rest : Color.primary)
            }
        }
        .padding(14)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - 退出确认(两阶段:冷静期 → 动态短语)

/// 解除锁定的完整摩擦流程:
/// 1. 番茄专注阶段 → 只展示承诺提示,无解锁入口(等休息窗口)。
/// 2. 冷静期倒计时(时长随近 7 天强退次数增长),随时可取消。
/// 3. 输入动态生成的确认短语(时间 + 已专注分钟 + 随机尾句)。
struct ExitConfirmationSheet: View {
    @EnvironmentObject private var engine: FocusEngine
    @Environment(\.dismiss) private var dismiss
    @State private var input = ""
    @State private var phrase: String?
    @State private var remainingCooldown = 0
    @State private var totalCooldown = 1

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    private var isCommitted: Bool { engine.isInPomodoroFocus }
    private var isCoolingDown: Bool { remainingCooldown > 0 }

    private var matches: Bool {
        guard let phrase else {
            return false
        }
        return ExitConfirmation.matches(input, phrase: phrase)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header

            if isCommitted {
                commitmentNotice
            } else if isCoolingDown {
                cooldownStage
            } else {
                phraseStage
            }

            HStack {
                Spacer()
                Button("继续专注") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)

                if !isCommitted, !isCoolingDown {
                    Button("结束并解锁") {
                        if engine.isSessionActive {
                            engine.endSessionEarly()
                        } else {
                            engine.setManualLock(false)
                        }
                        dismiss()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!matches)
                }
            }
        }
        .padding(24)
        .frame(width: 430)
        .background(Color.appBackground)
        .onAppear {
            startCooldown()
        }
        .onChange(of: isCommitted) { committed in
            // 番茄从专注切到休息:承诺解除,从头走冷静期
            if !committed {
                startCooldown()
            }
        }
        .onReceive(timer) { _ in
            guard !isCommitted, remainingCooldown > 0 else {
                return
            }
            remainingCooldown -= 1
            if remainingCooldown == 0 {
                generatePhrase()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: isCommitted ? "checkmark.seal.fill" : "hand.raised.fill")
                .font(.system(size: 22))
                .foregroundStyle(isCommitted ? Color.brand : Color.danger)
                .frame(width: 42, height: 42)
                .background(
                    (isCommitted ? Color.brand : Color.danger).opacity(0.1),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            VStack(alignment: .leading, spacing: 3) {
                Text(isCommitted ? "本轮专注已承诺" : "确定要解除锁定吗?")
                    .font(.system(size: 16, weight: .bold))
                Text(subtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var subtitle: String {
        if isCommitted {
            return "番茄钟专注阶段不可提前结束。"
        }
        return engine.isSessionActive ? "本次专注还没有完成。" : "手动锁定仍在生效。"
    }

    private var commitmentNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("开始番茄钟时,你已承诺完成每一轮专注。请等到休息窗口再做调整——那不会太久。")
                .font(.system(size: 13))
                .foregroundStyle(.primary)
            if case .focus(_, let remaining) = engine.pomodoroPhase {
                Text("距离下个休息窗口还有 \(DurationFormatter.countdown(remaining))")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.brand)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.brand.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }

    private var cooldownStage: some View {
        VStack(spacing: 12) {
            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.08), lineWidth: 6)
                Circle()
                    .trim(from: 0, to: CGFloat(remainingCooldown) / CGFloat(max(1, totalCooldown)))
                    .stroke(Color.danger, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .animation(.linear(duration: 1), value: remainingCooldown)
                Text("\(remainingCooldown)")
                    .font(.system(size: 26, weight: .bold, design: .monospaced))
                    .contentTransition(.numericText(countsDown: true))
            }
            .frame(width: 84, height: 84)

            Text("冷静一下,\(remainingCooldown) 秒后才能继续")
                .font(.system(size: 13, weight: .medium))
            if engine.recentTaintCount > 0 {
                Text("因近 7 天强制退出 \(engine.recentTaintCount) 次,冷静期已加长")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.danger)
            }
            Text("等待期间可以想想:真的有比完成这次专注更要紧的事吗?")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var phraseStage: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("请一字不差地输入下面这句话:")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)
            Text(phrase ?? "")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.danger)
                .textSelection(.disabled)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.danger.opacity(0.07), in: RoundedRectangle(cornerRadius: 7))

            TextField("在此输入", text: $input)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .padding(.horizontal, 12)
                .frame(height: 38)
                .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                .overlay {
                    RoundedRectangle(cornerRadius: 7)
                        .stroke(matches ? Color.success : Color.black.opacity(0.12))
                }
        }
    }

    private func startCooldown() {
        totalCooldown = max(1, engine.exitCooldownSeconds)
        remainingCooldown = totalCooldown
        input = ""
        phrase = nil
    }

    private func generatePhrase() {
        let focusedMinutes = engine.isSessionActive
            ? Int(engine.sessionFocusSeconds / 60)
            : nil
        phrase = ExitConfirmation.randomPhrase(now: Date(), focusedMinutes: focusedMinutes)
    }
}

// MARK: - 横幅

/// 强制退出后的「污点」通告:刻意不舒服,3 秒后才能关闭。
struct TaintNoticeBanner: View {
    let notice: TaintNotice
    let onDismiss: () -> Void
    @State private var dismissCountdown = 3

    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.octagon.fill")
                .font(.system(size: 18))
            VStack(alignment: .leading, spacing: 2) {
                Text("上次专注在 \(notice.occurredAt.formatted(.dateTime.hour().minute())) 被强制退出")
                    .font(.system(size: 13, weight: .bold))
                Text("这是近 7 天第 \(notice.recentCount) 次。强退不会让专注消失,只会让下次冷静期更长。")
                    .font(.system(size: 11))
                    .opacity(0.9)
            }
            Spacer()
            Button {
                onDismiss()
            } label: {
                Text(dismissCountdown > 0 ? "我知道了(\(dismissCountdown))" : "我知道了")
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 12)
                    .frame(height: 28)
                    .background(Color.white.opacity(0.18), in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(dismissCountdown > 0)
            .opacity(dismissCountdown > 0 ? 0.55 : 1)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color.danger, in: RoundedRectangle(cornerRadius: 9))
        .shadow(color: Color.danger.opacity(0.35), radius: 14, y: 5)
        .onReceive(timer) { _ in
            if dismissCountdown > 0 {
                dismissCountdown -= 1
            }
        }
    }
}

/// 网站屏蔽写入/解除失败(多为取消了密码框)。
struct HostsIssueBanner: View {
    let issue: HostsIssue
    let onRetry: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "globe.badge.chevron.backward")
                .font(.system(size: 15))
            Text(issue.message)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
            Button("重试", action: onRetry)
                .font(.system(size: 12, weight: .semibold))
                .buttonStyle(.plain)
                .padding(.horizontal, 12)
                .frame(height: 26)
                .background(Color.white.opacity(0.75), in: Capsule())
        }
        .foregroundStyle(Color.black.opacity(0.75))
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color.rest.opacity(0.92), in: RoundedRectangle(cornerRadius: 9))
        .shadow(color: .black.opacity(0.12), radius: 10, y: 4)
    }
}

struct BlockedBanner: View {
    let appName: String

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "hand.raised.fill")
                .foregroundStyle(Color.danger)
            Text("已拦截 \(appName)")
                .font(.system(size: 13, weight: .semibold))
        }
        .padding(.horizontal, 16)
        .frame(height: 42)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
    }
}

// MARK: - 专注页

private struct FocusView: View {
    @EnvironmentObject private var engine: FocusEngine
    @Binding var showExitConfirmation: Bool

    private let durations = [25, 45, 60, 90]
    private let pomodoroFocusOptions = [15, 25, 30, 45]
    private let pomodoroBreakOptions = [3, 5, 10]
    private let pomodoroRoundOptions = [2, 3, 4, 6]

    var body: some View {
        VStack(spacing: 0) {
            pageHeader
            Divider()
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    focusStage
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    Divider()
                    sessionRail
                        .frame(width: min(280, proxy.size.width * 0.32))
                }
            }
        }
    }

    private var pageHeader: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("专注")
                    .font(.system(size: 22, weight: .bold))
                Text(engine.now.formatted(.dateTime.year().month().day().weekday(.wide)))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                Circle()
                    .fill(engine.isLockEnabled ? Color.danger : Color.success)
                    .frame(width: 7, height: 7)
                Text(headerStatusText)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 30)
        .frame(height: 76)
        .background(Color.white)
    }

    private var headerStatusText: String {
        if engine.isInPomodoroRest {
            return "休息中,应用已解锁"
        }
        return engine.isLockEnabled ? "应用已锁定" : "白名单已就绪"
    }

    private var ringColor: Color {
        engine.isInPomodoroRest ? Color.rest : Color.brand
    }

    private var focusStage: some View {
        VStack(spacing: 24) {
            Spacer(minLength: 18)

            ZStack {
                Circle()
                    .stroke(Color.black.opacity(0.07), lineWidth: 12)
                Circle()
                    .trim(from: 0, to: engine.isSessionActive ? engine.progress : 1)
                    .stroke(
                        engine.isSessionActive ? ringColor : Color.black.opacity(0.12),
                        style: StrokeStyle(lineWidth: 12, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))
                    // 刻意不加 .animation:progress 每秒只变 1/总秒数(45 分钟会话是 0.037%),
                    // 补间出来的位移不到一个像素,肉眼看不出;但补间会让整个进程逐帧提交
                    // CoreAnimation 事务,而 macOS 26+ 每次提交都要拖着菜单栏项同步向
                    // 渲染服务器申请栅栏(见 AppleScriptRunner 注释),白白打满 WindowServer。

                stageCenter
                    .padding(26)
            }
            .frame(width: 310, height: 310)

            if engine.isSessionActive {
                Button {
                    showExitConfirmation = true
                } label: {
                    Label("提前结束", systemImage: "stop.fill")
                        .frame(minWidth: 138)
                }
                .buttonStyle(SecondaryActionButtonStyle())
            } else {
                Button {
                    engine.startSession()
                } label: {
                    Label("开始专注", systemImage: "play.fill")
                        .frame(minWidth: 150)
                }
                .buttonStyle(PrimaryActionButtonStyle())
            }

            Spacer(minLength: 18)
        }
        .padding(30)
    }

    @ViewBuilder
    private var stageCenter: some View {
        if engine.isSessionActive {
            VStack(spacing: 8) {
                Text(stageLabel)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(engine.isInPomodoroRest ? Color.rest : Color.secondary)
                Text(engine.primaryTimeText)
                    .font(.system(size: 48, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(stageSubtitle)
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(engine.isInPomodoroRest ? Color.rest : Color.brand)
                    .lineLimit(1)
                Text(currentClockText)
                    .font(.system(size: 13, weight: .medium, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 2)
            }
        } else {
            VStack(spacing: 9) {
                Text("当前时间")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(currentClockText)
                    .font(.system(size: 48, weight: .medium, design: .monospaced))
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
                Text("选择模式,开始学习")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(Color.secondary)
                if engine.timetable.isEnabled, let slot = engine.nextScheduledSlot {
                    Label("下一时段 \(slot.rangeText)", systemImage: "calendar.badge.clock")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.brand)
                }
            }
        }
    }

    private var currentClockText: String {
        engine.now.formatted(
            .dateTime.hour(.twoDigits(amPM: .omitted))
                .minute(.twoDigits)
                .second(.twoDigits)
        )
    }

    private var stageLabel: String {
        guard let session = engine.session else {
            return ""
        }
        switch session.mode {
        case .countdown:
            return "剩余时间"
        case .countUp:
            return "已专注"
        case .pomodoro:
            switch engine.pomodoroPhase {
            case .focus(let round, _):
                return "第 \(round)/\(session.schedule?.rounds ?? 0) 轮 · 专注"
            case .rest(let round, _):
                return "第 \(round)/\(session.schedule?.rounds ?? 0) 轮 · 休息"
            default:
                return "番茄钟"
            }
        }
    }

    private var stageSubtitle: String {
        guard let session = engine.session else {
            return ""
        }
        if engine.isInPomodoroRest {
            return "放松一下,别走远"
        }
        return session.title.isEmpty ? "保持专注" : session.title
    }

    private var sessionRail: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(title: "专注模式", symbol: "square.grid.2x2")
                    HStack(spacing: 6) {
                        ForEach(FocusMode.allCases) { mode in
                            Button {
                                engine.selectedMode = mode
                            } label: {
                                VStack(spacing: 5) {
                                    Image(systemName: mode.symbol)
                                        .font(.system(size: 15, weight: .medium))
                                    Text(mode.title)
                                        .font(.system(size: 11, weight: .semibold))
                                }
                                .frame(maxWidth: .infinity)
                                .frame(height: 58)
                                .background(
                                    engine.selectedMode == mode
                                        ? Color.brand.opacity(0.13)
                                        : Color.white,
                                    in: RoundedRectangle(cornerRadius: 7)
                                )
                                .foregroundStyle(
                                    engine.selectedMode == mode ? Color.brand : Color.primary
                                )
                            }
                            .buttonStyle(.plain)
                            .disabled(engine.isSessionActive)
                        }
                    }
                }

                modeParameters

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(title: "学习任务", symbol: "pencil.line")
                    TextField("准备完成什么?", text: $engine.sessionTitle)
                        .textFieldStyle(.plain)
                        .padding(.horizontal, 12)
                        .frame(height: 40)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                        .overlay {
                            RoundedRectangle(cornerRadius: 7)
                                .stroke(Color.black.opacity(0.08))
                        }
                        .disabled(engine.isSessionActive)
                }

                VStack(alignment: .leading, spacing: 12) {
                    SectionLabel(title: "今日进度", symbol: "chart.line.uptrend.xyaxis")
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            StatValue(value: "\(engine.todayFocusedMinutes)", unit: "分钟")
                            Divider().frame(height: 34)
                            StatValue(value: "\(engine.todayCompletedSessionCount)", unit: "次完成")
                        }
                        StreakLine()
                    }
                    .padding(14)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                }
            }
            .padding(24)
        }
        .background(Color.panelBackground)
    }

    @ViewBuilder
    private var modeParameters: some View {
        switch engine.selectedMode {
        case .countdown:
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "专注时长", symbol: "hourglass")
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: 2),
                    spacing: 8
                ) {
                    ForEach(durations, id: \.self) { minutes in
                        OptionChip(
                            text: "\(minutes) 分钟",
                            isSelected: engine.selectedMinutes == minutes,
                            isDisabled: engine.isSessionActive
                        ) {
                            engine.selectDuration(minutes)
                        }
                    }
                }
            }
        case .countUp:
            VStack(alignment: .leading, spacing: 12) {
                SectionLabel(title: "说明", symbol: "info.circle")
                Text("正计时会一直锁定并累计专注时间,结束时需经过冷静期并输入确认短语。")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
            }
        case .pomodoro:
            VStack(alignment: .leading, spacing: 14) {
                OptionRow(
                    title: "专注",
                    options: pomodoroFocusOptions,
                    unit: "分",
                    selection: $engine.pomodoroFocusMinutes,
                    isDisabled: engine.isSessionActive
                )
                OptionRow(
                    title: "休息",
                    options: pomodoroBreakOptions,
                    unit: "分",
                    selection: $engine.pomodoroBreakMinutes,
                    isDisabled: engine.isSessionActive
                )
                OptionRow(
                    title: "轮数",
                    options: pomodoroRoundOptions,
                    unit: "轮",
                    selection: $engine.pomodoroRounds,
                    isDisabled: engine.isSessionActive
                )
                Text("专注阶段承诺不可提前结束;休息期间自动解锁,进入下一轮自动重新锁定。")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// 连续打卡展示:进行中 / 今天未打卡告警 / 断签。
struct StreakLine: View {
    @EnvironmentObject private var engine: FocusEngine

    var body: some View {
        let streak = engine.streakDays
        HStack(spacing: 6) {
            if streak > 0 {
                Text("🔥 连续 \(streak) 天")
                    .font(.system(size: 12, weight: .bold))
                if !engine.hasCompletedToday {
                    Text("今天还未打卡,断签将清零")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.danger)
                }
            } else if engine.records.contains(where: \.completed) {
                Text("已断签,今天完成一次即可重新开始")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            } else {
                Text("完成第一次专注,开始连续打卡")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct OptionRow: View {
    let title: String
    let options: [Int]
    let unit: String
    @Binding var selection: Int
    let isDisabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("\(title) · \(selection) \(unit)")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                ForEach(options, id: \.self) { value in
                    OptionChip(
                        text: "\(value)",
                        isSelected: selection == value,
                        isDisabled: isDisabled
                    ) {
                        selection = value
                    }
                }
            }
        }
    }
}

private struct OptionChip: View {
    let text: String
    let isSelected: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(text)
                .font(.system(size: 12, weight: .semibold))
                .frame(maxWidth: .infinity)
                .frame(height: 36)
                .background(
                    isSelected ? Color.brand.opacity(0.13) : Color.white,
                    in: RoundedRectangle(cornerRadius: 7)
                )
                .foregroundStyle(isSelected ? Color.brand : Color.primary)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
    }
}

// MARK: - 定时课程表

/// 定时专注设置:总开关、时段增删改、星期生效、跳过/补班日期。
private struct ScheduleView: View {
    @EnvironmentObject private var engine: FocusEngine
    @State private var skipDatePick = Date()
    @State private var forceDatePick = Date()

    /// 周一~周日展示顺序对应 Calendar.weekday 值。
    private static let weekdayOrder = [2, 3, 4, 5, 6, 7, 1]
    private static let weekdayNames = [1: "日", 2: "一", 3: "二", 4: "三", 5: "四", 6: "五", 7: "六"]

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    slotSection
                    weekdaySection
                    dateSection(
                        title: "跳过日期(节假日)",
                        symbol: "calendar.badge.minus",
                        dates: engine.timetable.skipDates,
                        pick: $skipDatePick,
                        emptyHint: "法定节假日等不想自动锁定的日子,加进来当天整天不生效。",
                        onAdd: { engine.addSkipDate(skipDatePick) },
                        onRemove: { engine.removeSkipDate($0) }
                    )
                    dateSection(
                        title: "补班日期(强制生效)",
                        symbol: "calendar.badge.plus",
                        dates: engine.timetable.forceDates,
                        pick: $forceDatePick,
                        emptyHint: "调休补班的周末加进来,即使不在生效星期内当天也按课程表锁定。",
                        onAdd: { engine.addForceDate(forceDatePick) },
                        onRemove: { engine.removeForceDate($0) }
                    )

                    Text(
                        """
                        说明:到达时段自动开始倒计时专注并锁定,时段结束自动解锁;时段之间的空隙不锁定。\
                        中途打开应用会立即锁定至本时段结束。走冷静期并输入确认短语提前结束后,\
                        该时段当天不再自动重启。时段开始时若已有手动会话或手动锁定,不会被打断——\
                        其结束后若仍在时段内会自动接上定时专注。
                        """
                    )
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
                }
                .padding(24)
            }
            .background(Color.appBackground)
        }
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text("定时专注")
                    .font(.system(size: 22, weight: .bold))
                Text(headerSubtitle)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle("启用", isOn: Binding(
                get: { engine.timetable.isEnabled },
                set: { engine.setTimetableEnabled($0) }
            ))
            .toggleStyle(.switch)
            .font(.system(size: 13, weight: .medium))
        }
        .padding(.horizontal, 30)
        .frame(height: 76)
        .background(Color.white)
    }

    private var headerSubtitle: String {
        guard engine.timetable.isEnabled else {
            return "按课程表自动开启专注、间隙自动解锁"
        }
        if let slot = engine.nextScheduledSlot {
            return "今日下一时段 \(slot.rangeText)"
        }
        return TimetableScheduler.isActiveDay(engine.now, timetable: engine.timetable)
            ? "今日剩余时段已全部结束"
            : "今天不在生效日(星期/日期设置)"
    }

    private var slotSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                SectionLabel(title: "时段(\(engine.timetable.slots.count))", symbol: "clock")
                Spacer()
                Button {
                    engine.addSlot()
                } label: {
                    Label("添加时段", systemImage: "plus")
                        .font(.system(size: 12, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.brand)
            }

            if !engine.isTimetableValid {
                Text("时段存在重叠或开始不早于结束,请调整后定时才会生效")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.danger)
            }

            VStack(spacing: 8) {
                ForEach(Array(engine.timetable.slots.enumerated()), id: \.element.id) { index, slot in
                    SlotRow(index: index + 1, slot: slot) { updated in
                        engine.updateSlot(updated)
                    } onDelete: {
                        engine.removeSlot(slot)
                    }
                }
            }
        }
    }

    private var weekdaySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: "生效星期", symbol: "calendar")
            HStack(spacing: 6) {
                ForEach(Self.weekdayOrder, id: \.self) { weekday in
                    let selected = engine.timetable.activeWeekdays.contains(weekday)
                    Button {
                        engine.toggleWeekday(weekday)
                    } label: {
                        Text(Self.weekdayNames[weekday] ?? "")
                            .font(.system(size: 12, weight: .semibold))
                            .frame(maxWidth: .infinity)
                            .frame(height: 36)
                            .background(
                                selected ? Color.brand.opacity(0.13) : Color.white,
                                in: RoundedRectangle(cornerRadius: 7)
                            )
                            .foregroundStyle(selected ? Color.brand : Color.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func dateSection(
        title: String,
        symbol: String,
        dates: [Date],
        pick: Binding<Date>,
        emptyHint: String,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (Date) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(title: title, symbol: symbol)
            HStack(spacing: 8) {
                DatePicker("", selection: pick, displayedComponents: .date)
                    .datePickerStyle(.field)
                    .labelsHidden()
                Button("添加", action: onAdd)
                    .buttonStyle(.plain)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .frame(height: 30)
                    .background(Color.brand, in: RoundedRectangle(cornerRadius: 7))
            }
            if dates.isEmpty {
                Text(emptyHint)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                FlowChips(
                    items: dates.map { $0.formatted(.dateTime.year().month().day()) },
                    isAdded: { _ in false },
                    isDisabled: false
                ) { text in
                    if let date = dates.first(where: {
                        $0.formatted(.dateTime.year().month().day()) == text
                    }) {
                        onRemove(date)
                    }
                }
            }
        }
    }
}

/// 单个时段编辑行:序号 + 开始/结束时间选择 + 删除。
private struct SlotRow: View {
    let index: Int
    let slot: TimeSlot
    let onUpdate: (TimeSlot) -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Text("\(index)")
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.brand)
                .frame(width: 24, height: 24)
                .background(Color.brand.opacity(0.1), in: Circle())

            DatePicker("", selection: timeBinding(\.startMinute), displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .labelsHidden()
            Text("–")
                .foregroundStyle(.secondary)
            DatePicker("", selection: timeBinding(\.endMinute), displayedComponents: .hourAndMinute)
                .datePickerStyle(.field)
                .labelsHidden()

            Text(durationText)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)

            Spacer()

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .frame(height: 48)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var durationText: String {
        let minutes = slot.endMinute - slot.startMinute
        return minutes > 0 ? "\(minutes) 分钟" : "无效"
    }

    /// minuteOfDay ↔ Date(锚定今天)的转换绑定,供 DatePicker 使用。
    private func timeBinding(_ keyPath: WritableKeyPath<TimeSlot, Int>) -> Binding<Date> {
        Binding<Date>(
            get: {
                let start = Calendar.current.startOfDay(for: Date())
                return start.addingTimeInterval(TimeInterval(slot[keyPath: keyPath] * 60))
            },
            set: { newValue in
                var updated = slot
                updated[keyPath: keyPath] = TimetableScheduler.minuteOfDay(newValue)
                onUpdate(updated)
            }
        )
    }
}

// MARK: - 白名单(应用 + 网站)

private enum WhitelistTab: String, CaseIterable, Identifiable {
    case apps
    case websites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .apps: "应用"
        case .websites: "网站"
        }
    }
}

private struct WhitelistView: View {
    @EnvironmentObject private var engine: FocusEngine
    @State private var tab: WhitelistTab = .apps
    @State private var searchText = ""

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(tab == .apps ? "应用白名单" : "网站黑名单")
                        .font(.system(size: 22, weight: .bold))
                    Text(headerSubtitle)
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Picker("", selection: $tab) {
                    ForEach(WhitelistTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 170)

                if tab == .apps {
                    searchField
                    Button {
                        engine.reloadApplications()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                            .frame(width: 32, height: 32)
                    }
                    .buttonStyle(.plain)
                    .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 7))
                    .help("重新扫描应用")
                }
            }
            .padding(.horizontal, 30)
            .frame(height: 76)
            .background(Color.white)

            Divider()

            switch tab {
            case .apps:
                appList
            case .websites:
                WebsiteBlocklistView()
            }

            if engine.isLockEnabled {
                HStack(spacing: 8) {
                    Image(systemName: "lock.fill")
                    Text("锁定期间不能修改应用白名单和网站允许列表")
                }
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(Color.danger)
                .frame(maxWidth: .infinity)
                .frame(height: 42)
                .background(Color.danger.opacity(0.08))
            }
        }
    }

    private var headerSubtitle: String {
        switch tab {
        case .apps:
            return "已允许 \(engine.whitelist.count) 个应用"
        case .websites:
            return "锁定期间浏览器只允许访问 \(engine.allowedDomains.count) 个网站(其余标签自动清空)"
        }
    }

    private var filteredApps: [InstalledApp] {
        guard !searchText.isEmpty else {
            return engine.installedApps
        }
        return engine.installedApps.filter {
            $0.name.localizedCaseInsensitiveContains(searchText)
                || ($0.bundleIdentifier?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    @ViewBuilder
    private var appList: some View {
        if engine.isLoadingApps {
            Spacer()
            ProgressView()
                .controlSize(.small)
            Text("正在扫描应用")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.top, 10)
            Spacer()
        } else {
            List(filteredApps) { app in
                AppRow(
                    app: app,
                    isAllowed: engine.whitelist.contains(app.id),
                    isDisabled: engine.isLockEnabled,
                    isForceBlacklisted: engine.isForceBlacklisted(app)
                ) {
                    engine.toggleWhitelist(for: app)
                }
                .listRowInsets(EdgeInsets(top: 5, leading: 24, bottom: 5, trailing: 24))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            }
            .listStyle(.plain)
            .scrollContentBackground(.hidden)
            .background(Color.appBackground)
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("搜索应用", text: $searchText)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10)
        .frame(width: 200, height: 34)
        .background(Color.appBackground, in: RoundedRectangle(cornerRadius: 7))
    }
}

/// 网站白名单管理:专注期间浏览器只允许访问这些域名,其余标签自动导离。
private struct WebsiteBlocklistView: View {
    @EnvironmentObject private var engine: FocusEngine
    @State private var input = ""
    @State private var showInvalidHint = false

    private static let presets = [
        "wikipedia.org", "github.com", "stackoverflow.com", "developer.apple.com",
        "khanacademy.org", "coursera.org", "translate.google.com", "zdic.net"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "添加允许的网站", symbol: "plus.circle")
                    HStack(spacing: 8) {
                        TextField("输入域名,如 wikipedia.org(自动包含子域名)", text: $input)
                            .textFieldStyle(.plain)
                            .font(.system(size: 13))
                            .padding(.horizontal, 12)
                            .frame(height: 38)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 7))
                            .overlay {
                                RoundedRectangle(cornerRadius: 7)
                                    .stroke(
                                        showInvalidHint
                                            ? Color.danger
                                            : Color.black.opacity(0.1)
                                    )
                            }
                            .onSubmit(addDomain)
                            .disabled(engine.isLockEnabled)
                        Button("添加", action: addDomain)
                            .buttonStyle(.plain)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 18)
                            .frame(height: 38)
                            .background(Color.brand, in: RoundedRectangle(cornerRadius: 7))
                            .disabled(engine.isLockEnabled || input.isEmpty)
                            .opacity(engine.isLockEnabled || input.isEmpty ? 0.5 : 1)
                    }
                    if showInvalidHint {
                        Text("这看起来不是有效的域名")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.danger)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(title: "常见学习站点", symbol: "sparkles")
                    FlowChips(
                        items: Self.presets,
                        isAdded: { engine.allowedDomains.contains($0) },
                        isDisabled: engine.isLockEnabled
                    ) { domain in
                        engine.addAllowedDomain(domain)
                    }
                }

                VStack(alignment: .leading, spacing: 10) {
                    SectionLabel(
                        title: "允许列表(\(engine.allowedDomains.count))",
                        symbol: "checkmark.shield"
                    )
                    if engine.allowedDomains.isEmpty {
                        Text("尚未添加。锁定期间浏览器里打开的任何网页都会被清空——如需上网查资料,请先把常用站点加进来。")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                    } else {
                        VStack(spacing: 8) {
                            ForEach(engine.allowedDomains, id: \.self) { domain in
                                HStack {
                                    Image(systemName: "globe")
                                        .foregroundStyle(Color.brand)
                                    Text(domain)
                                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                                    Spacer()
                                    Button {
                                        engine.removeAllowedDomain(domain)
                                    } label: {
                                        Image(systemName: "trash")
                                            .frame(width: 28, height: 28)
                                    }
                                    .buttonStyle(.plain)
                                    .foregroundStyle(.secondary)
                                    .disabled(engine.isLockEnabled)
                                }
                                .padding(.horizontal, 14)
                                .frame(height: 46)
                                .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
                            }
                        }
                    }
                }

                Text(
                    """
                    工作原理:锁定期间每 2 秒检查所有已打开浏览器(Safari、Chrome、Edge、\
                    Arc、Brave、Vivaldi,含 Beta/Dev/Canary 各渠道)的每一个标签页,\
                    不在允许列表的网页立即清空为空白页(后台标签也一样,点「后退」可恢复)。\
                    此方式在浏览器层工作,兼容你的 Clash / WARP 等任何代理或 VPN,无需改动网络设置;\
                    子域名自动包含。仅覆盖上述可脚本化浏览器——其他应用已被整体隐藏无法使用。\
                    首次使用需在系统弹窗中允许「认真」控制浏览器(自动化权限)。
                    """
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
            }
            .padding(24)
        }
        .background(Color.appBackground)
    }

    private func addDomain() {
        guard !input.isEmpty else {
            return
        }
        if engine.addAllowedDomain(input) {
            input = ""
            showInvalidHint = false
        } else {
            showInvalidHint = true
        }
    }
}

/// 简单的自动换行 chip 组。
private struct FlowChips: View {
    let items: [String]
    let isAdded: (String) -> Bool
    let isDisabled: Bool
    let onTap: (String) -> Void

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 128), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(items, id: \.self) { item in
                let added = isAdded(item)
                Button {
                    onTap(item)
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: added ? "checkmark" : "plus")
                            .font(.system(size: 9, weight: .bold))
                        Text(item)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 30)
                    .frame(maxWidth: .infinity)
                    .background(
                        added ? Color.brand.opacity(0.12) : Color.white,
                        in: Capsule()
                    )
                    .foregroundStyle(added ? Color.brand : Color.primary)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled || added)
            }
        }
    }
}

private struct AppRow: View {
    let app: InstalledApp
    let isAllowed: Bool
    let isDisabled: Bool
    let isForceBlacklisted: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            Image(nsImage: app.icon)
                .resizable()
                .scaledToFit()
                .frame(width: 38, height: 38)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(1)
                Text(app.bundleIdentifier ?? app.url.path)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer()

            if isForceBlacklisted {
                Text("锁定期强制隐藏")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Color.danger)
                    .padding(.horizontal, 8)
                    .frame(height: 20)
                    .background(Color.danger.opacity(0.1), in: Capsule())
                    .help("为防止锁定期间修改系统配置,该应用始终被隐藏,无法加入白名单")
            } else {
                Button(action: action) {
                    Image(systemName: isAllowed ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 21))
                        .foregroundStyle(isAllowed ? Color.brand : Color.secondary.opacity(0.55))
                        .frame(width: 34, height: 34)
                }
                .buttonStyle(.plain)
                .disabled(isDisabled)
                .help(isAllowed ? "从白名单移除" : "加入白名单")
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 62)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
        .opacity(isDisabled ? 0.65 : 1)
    }
}

// MARK: - 记录页

private struct HistoryView: View {
    @EnvironmentObject private var engine: FocusEngine

    private var completedMinutes: Int {
        engine.records.filter(\.completed).reduce(0) { $0 + $1.focusedMinutes }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("专注记录")
                        .font(.system(size: 22, weight: .bold))
                    Text("累计专注 \(completedMinutes) 分钟")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if !engine.records.isEmpty {
                    ExportReportMenu()
                }
            }
            .padding(.horizontal, 30)
            .frame(height: 76)
            .background(Color.white)

            Divider()

            if engine.records.isEmpty {
                Spacer()
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 34, weight: .light))
                    .foregroundStyle(.tertiary)
                Text("暂无专注记录")
                    .font(.system(size: 14, weight: .medium))
                    .padding(.top, 12)
                Spacer()
            } else {
                ScrollView {
                    VStack(spacing: 18) {
                        FocusTrendPanel()
                        LazyVStack(spacing: 9) {
                            ForEach(engine.records) { record in
                                RecordRow(record: record) {
                                    engine.removeRecord(record)
                                }
                            }
                        }
                    }
                    .padding(24)
                }
            }
        }
    }
}

/// 导出 Markdown 专注报告(近 7 / 30 天)。
private struct ExportReportMenu: View {
    @EnvironmentObject private var engine: FocusEngine

    var body: some View {
        Menu {
            Button("近 7 天报告") {
                export(days: 7)
            }
            Button("近 30 天报告") {
                export(days: 30)
            }
        } label: {
            Label("导出报告", systemImage: "square.and.arrow.up")
                .font(.system(size: 12, weight: .semibold))
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .padding(.horizontal, 12)
        .frame(height: 32)
        .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
        .foregroundStyle(Color.brand)
        .help("生成 Markdown 报告到「下载」目录,含使用时长汇总与会话明细")
    }

    private func export(days: Int) {
        guard let url = engine.exportReport(days: days) else {
            NSSound(named: "Basso")?.play()
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

private struct RecordRow: View {
    let record: FocusRecord
    let onDelete: () -> Void
    @State private var isExpanded = false

    private var isForceQuit: Bool { record.endReason == .forceQuit }
    private var hasUsage: Bool { !(record.usage?.isEmpty ?? true) }
    private var hasBlocked: Bool { !(record.blockedNetworkDomains?.isEmpty ?? true) }
    private var isExpandable: Bool { hasUsage || hasBlocked }

    private var statusTitle: String {
        if record.completed {
            return "完成专注"
        }
        return isForceQuit ? "强制退出" : "提前结束"
    }

    private var statusSymbol: String {
        if record.completed {
            return "checkmark"
        }
        return isForceQuit ? "bolt.slash.fill" : "xmark"
    }

    private var statusColor: Color {
        if record.completed {
            return .success
        }
        return isForceQuit ? .danger : .secondary
    }

    var body: some View {
        VStack(spacing: 0) {
            headerRow
            if isExpanded {
                if let usage = record.usage, !usage.isEmpty {
                    Divider()
                        .padding(.horizontal, 16)
                    UsageDetail(usage: usage)
                        .padding(16)
                }
                if let blocked = record.blockedNetworkDomains, !blocked.isEmpty {
                    Divider()
                        .padding(.horizontal, 16)
                    BlockedDomainsDetail(domains: blocked)
                        .padding(16)
                }
            }
        }
        .background(Color.white, in: RoundedRectangle(cornerRadius: 8))
    }

    private var headerRow: some View {
        HStack(spacing: 14) {
            Image(systemName: statusSymbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(statusColor)
                .frame(width: 30, height: 30)
                .background(statusColor.opacity(0.11), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text(statusTitle)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(isForceQuit ? Color.danger : Color.primary)
                HStack(spacing: 6) {
                    Text(record.startedAt.formatted(.dateTime.month().day().hour().minute()))
                    if let count = record.interruptionCount, count > 0 {
                        Text("· 拦截 \(count) 次")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Text(record.mode.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(Color.brand)
                .padding(.horizontal, 8)
                .frame(height: 20)
                .background(Color.brand.opacity(0.1), in: Capsule())

            Spacer()

            if let score = record.qualityScore {
                QualityBadge(score: score)
            }

            Text("\(record.focusedMinutes) 分钟")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))

            if isExpandable {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) {
                        isExpanded.toggle()
                    }
                } label: {
                    Image(systemName: "chevron.down")
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("查看应用/网站使用明细")
            }

            Button(action: onDelete) {
                Image(systemName: "trash")
                    .frame(width: 30, height: 30)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("删除记录")
        }
        .padding(.horizontal, 16)
        .frame(height: 66)
        .contentShape(Rectangle())
        .onTapGesture {
            guard isExpandable else {
                return
            }
            withAnimation(.easeOut(duration: 0.15)) {
                isExpanded.toggle()
            }
        }
    }
}

/// 会话内应用/网站使用时长明细(时长降序 + 比例条)。
private struct UsageDetail: View {
    let usage: UsageTally

    var body: some View {
        HStack(alignment: .top, spacing: 24) {
            column(title: "应用", symbol: "macwindow", entries: usage.topApps)
            if !usage.sites.isEmpty {
                column(title: "网站", symbol: "globe", entries: usage.topSites)
            }
        }
    }

    private func column(
        title: String,
        symbol: String,
        entries: [(name: String, seconds: Int)]
    ) -> some View {
        let maxSeconds = max(1, entries.first?.seconds ?? 1)
        return VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: title, symbol: symbol)
            ForEach(entries.prefix(6), id: \.name) { entry in
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(entry.name)
                            .font(.system(size: 12, weight: .medium))
                            .lineLimit(1)
                        Spacer()
                        Text(FocusReport.durationText(entry.seconds))
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    GeometryReader { proxy in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(Color.brand.opacity(0.75))
                            .frame(
                                width: proxy.size.width
                                    * CGFloat(entry.seconds) / CGFloat(maxSeconds)
                            )
                    }
                    .frame(height: 4)
                    .background(Color.black.opacity(0.05), in: RoundedRectangle(cornerRadius: 2))
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 会话内被网络门禁拦截的域名(去重列表)。
private struct BlockedDomainsDetail: View {
    let domains: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectionLabel(title: "被拦网站(\(domains.count))", symbol: "hand.raised.slash")
            Text(domains.prefix(30).joined(separator: "  ·  "))
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(Color.danger.opacity(0.85))
            if domains.count > 30 {
                Text("… 及另外 \(domains.count - 30) 个")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 质量分徽章(≥85 绿 / ≥60 橙 / 其余红)。
struct QualityBadge: View {
    let score: Int

    private var color: Color {
        if score >= 85 {
            return .success
        }
        return score >= 60 ? .rest : .danger
    }

    var body: some View {
        Text("质量 \(score)")
            .font(.system(size: 10, weight: .bold, design: .monospaced))
            .foregroundStyle(color)
            .padding(.horizontal, 8)
            .frame(height: 20)
            .background(color.opacity(0.1), in: Capsule())
            .help("基础 100 分;每次拦截 −8,提前结束 −25,强制退出 −50")
    }
}

// MARK: - 趋势图

private enum TrendRange: Int, CaseIterable, Identifiable {
    case week = 7
    case month = 30

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .week: "近 7 天"
        case .month: "近 30 天"
        }
    }
}

/// 每日专注分钟柱状图;柱色按当日平均质量分分档(绿/橙/红),
/// 无质量数据的日子用品牌色。虚线为区间日均。
struct FocusTrendPanel: View {
    @EnvironmentObject private var engine: FocusEngine
    @State private var range: TrendRange = .week

    private var dailyData: [DailyFocus] {
        engine.dailyFocus(days: range.rawValue)
    }

    private var totalMinutes: Int {
        dailyData.reduce(0) { $0 + $1.focusedMinutes }
    }

    private var averageMinutes: Int {
        dailyData.isEmpty ? 0 : totalMinutes / dailyData.count
    }

    private var averageQuality: Int? {
        let scores = dailyData.compactMap(\.averageQuality)
        guard !scores.isEmpty else {
            return nil
        }
        return scores.reduce(0, +) / scores.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                SectionLabel(title: "专注趋势", symbol: "chart.bar.fill")
                Spacer()
                Picker("", selection: $range) {
                    ForEach(TrendRange.allCases) { range in
                        Text(range.title).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 180)
            }

            HStack {
                StatValue(value: "\(totalMinutes)", unit: "合计分钟")
                Divider().frame(height: 34)
                StatValue(value: "\(averageMinutes)", unit: "日均分钟")
                Divider().frame(height: 34)
                StatValue(
                    value: averageQuality.map(String.init) ?? "—",
                    unit: "平均质量"
                )
            }

            chart
                .frame(height: 190)

            HStack(spacing: 14) {
                legendDot(color: .success, label: "质量 ≥ 85")
                legendDot(color: .rest, label: "60 – 84")
                legendDot(color: .danger, label: "< 60")
                legendDot(color: .brand, label: "无质量数据")
            }
        }
        .padding(18)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 10))
    }

    private var chart: some View {
        Chart(dailyData) { item in
            BarMark(
                x: .value("日期", item.day, unit: .day),
                y: .value("分钟", item.focusedMinutes)
            )
            .foregroundStyle(barColor(for: item))
            .cornerRadius(3)

            if averageMinutes > 0 {
                RuleMark(y: .value("日均", averageMinutes))
                    .foregroundStyle(Color.secondary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .day, count: range == .week ? 1 : 5)) { _ in
                AxisGridLine()
                    .foregroundStyle(Color.black.opacity(0.05))
                AxisValueLabel(
                    format: .dateTime.month(.defaultDigits).day(),
                    centered: range == .week
                )
                .font(.system(size: 10))
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine()
                    .foregroundStyle(Color.black.opacity(0.06))
                AxisValueLabel {
                    if let minutes = value.as(Int.self) {
                        Text("\(minutes)")
                            .font(.system(size: 10))
                    }
                }
            }
        }
    }

    private func barColor(for item: DailyFocus) -> Color {
        guard let quality = item.averageQuality else {
            return .brand
        }
        if quality >= 85 {
            return .success
        }
        return quality >= 60 ? .rest : .danger
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - 通用组件

struct SectionLabel: View {
    let title: String
    let symbol: String

    var body: some View {
        Label(title, systemImage: symbol)
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(.secondary)
    }
}

struct StatValue: View {
    let value: String
    let unit: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 24, weight: .bold, design: .rounded))
            Text(unit)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct PrimaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 22)
            .frame(height: 44)
            .background(
                configuration.isPressed ? Color.brand.opacity(0.82) : Color.brand,
                in: RoundedRectangle(cornerRadius: 8)
            )
    }
}

struct SecondaryActionButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(Color.danger)
            .padding(.horizontal, 22)
            .frame(height: 42)
            .background(Color.danger.opacity(configuration.isPressed ? 0.14 : 0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}

extension Color {
    static let brand = Color(red: 0.10, green: 0.49, blue: 0.38)
    static let success = Color(red: 0.12, green: 0.58, blue: 0.40)
    static let danger = Color(red: 0.84, green: 0.25, blue: 0.25)
    static let rest = Color(red: 0.85, green: 0.55, blue: 0.15)
    static let appBackground = Color(red: 0.95, green: 0.96, blue: 0.96)
    static let sidebarBackground = Color(red: 0.92, green: 0.93, blue: 0.93)
    static let panelBackground = Color(red: 0.93, green: 0.95, blue: 0.95)
}
