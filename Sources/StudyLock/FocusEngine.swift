import AppKit
import Combine
import Foundation

/// 启动时发现上次被强制退出后,给用户看的「污点」通告。
struct TaintNotice: Equatable {
    let occurredAt: Date
    let recentCount: Int
}

/// 监控/清理类问题横幅。
enum HostsIssue: Equatable {
    /// 旧版 hosts 屏蔽块残留且移除失败(取消了密码框)。
    case removeFailed
    /// 浏览器自动化权限被拒,无法检查/拦截网页。
    case browserPermissionDenied

    var message: String {
        switch self {
        case .removeFailed:
            "旧版网站屏蔽残留未清理(需要管理员密码)"
        case .browserPermissionDenied:
            "无法检查浏览器网页。请到 系统设置 → 隐私与安全 → 自动化 中允许「认真」控制浏览器"
        }
    }
}

@MainActor
final class FocusEngine: ObservableObject {
    @Published var now = Date()
    @Published var selectedMode: FocusMode = .countdown
    @Published var selectedMinutes = 45
    @Published var pomodoroFocusMinutes = 25
    @Published var pomodoroBreakMinutes = 5
    @Published var pomodoroRounds = 4
    @Published var sessionTitle = ""
    @Published private(set) var session: ActiveSession?
    @Published private(set) var isLockEnabled = false
    @Published private(set) var isManualLockOn = false
    @Published private(set) var blockedAppName: String?
    @Published private(set) var installedApps: [InstalledApp] = []
    @Published private(set) var isLoadingApps = true
    @Published private(set) var whitelist: Set<String>
    @Published private(set) var records: [FocusRecord]
    @Published private(set) var allowedDomains: [String]
    @Published private(set) var taintNotice: TaintNotice?
    @Published private(set) var hostsIssue: HostsIssue?
    @Published private(set) var sessionInterruptions = 0
    @Published private(set) var timetable: FocusTimetable = .default

    private let enforcer = LockEnforcer()
    private let hostsBlocker = HostsBlocker()
    private let browserMonitor = BrowserMonitor()
    private var blockedNetworkDomains: Set<String> = []
    private var lastActiveBlocked: String?
    private var currentUsage = UsageTally()
    private var secondsSinceSample = 0
    /// 在途的浏览器扫描;非 nil 表示上一轮还没回来,本轮跳过。
    private var sweepTask: Task<Void, Never>?
    private var clockTimer: Timer?
    private var blockedBannerTask: Task<Void, Never>?
    private var wasInPomodoroRest = false
    private var lastHeartbeatWrite = Date.distantPast
    /// 提前结束/已完成的「时段|日期」键:当天该时段不再自动重启。
    private var dismissedSlotKeys: Set<String> = []
    /// 确认退出后置位:停止采样与横幅刷新。
    private var isQuitting = false
    private let defaults = UserDefaults.standard

    private enum Keys {
        static let whitelist = "whitelist.v1"
        static let legacyRecords = "focusRecords.v1"
        static let records = "focusRecords.v2"
        static let session = "activeSession.v1"
        static let heartbeat = "heartbeat.v1"
        static let interruptions = "interruptions.v1"
        static let manualLock = "manualLock.v1"
        static let taints = "taints.v1"
        /// v2.1 的黑名单键,已废弃(白名单语义相反,不迁移)。
        static let legacyBlockedDomains = "blockedDomains.v1"
        static let allowedDomains = "allowedDomains.v1"
        static let usage = "usage.v1"
        static let proxySnapshot = "proxySnapshot.v1"
        static let timetable = "timetable.v1"
        static let dismissedSlots = "dismissedSlots.v1"
    }

    /// 心跳写入节流间隔;恢复决策的宽限期见 RecoveryDecision.heartbeatGrace。
    private static let heartbeatInterval: TimeInterval = 10

    init() {
        #if DEBUG
        // --debug-reset-state:清空全部持久化状态,方便端到端验证从干净环境开始。
        if ProcessInfo.processInfo.arguments.contains("--debug-reset-state") {
            for key in [
                Keys.whitelist, Keys.records, Keys.session, Keys.heartbeat,
                Keys.interruptions, Keys.manualLock, Keys.taints,
                Keys.legacyBlockedDomains, Keys.allowedDomains, Keys.usage,
                Keys.proxySnapshot, Keys.timetable, Keys.dismissedSlots
            ] {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        #endif

        whitelist = Set(defaults.stringArray(forKey: Keys.whitelist) ?? [])
        records = Self.loadRecords(from: defaults)
        allowedDomains = defaults.stringArray(forKey: Keys.allowedDomains) ?? []
        // v2.1 黑名单键已废弃(语义相反,不迁移)
        defaults.removeObject(forKey: Keys.legacyBlockedDomains)
        timetable = Self.loadTimetable(from: defaults)
        dismissedSlotKeys = Self.loadDismissedSlotKeys(from: defaults, today: Date())

        enforcer.onBlocked = { [weak self] appName in
            self?.registerBlocked(appName)
        }
        browserMonitor.onPermissionDenied = { [weak self] in
            self?.hostsIssue = .browserPermissionDenied
        }

        clockTimer = Timer.scheduledTimer(
            withTimeInterval: 1,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.tick()
            }
        }

        loadApplications()
        recoverFromAbnormalTermination()

        #if DEBUG
        // 仅调试构建:自动化端到端验证钩子(release 构建不包含此代码)。
        // --debug-whitelist a,b,c  用给定白名单覆盖(仅内存,不写入偏好)
        // --debug-lock-seconds N   启动后立即手动锁定,N 秒后自动解锁
        let arguments = ProcessInfo.processInfo.arguments
        if
            let index = arguments.firstIndex(of: "--debug-whitelist"),
            index + 1 < arguments.count
        {
            whitelist = Set(arguments[index + 1].split(separator: ",").map(String.init))
        }
        if
            let index = arguments.firstIndex(of: "--debug-lock-seconds"),
            index + 1 < arguments.count,
            let seconds = Int(arguments[index + 1])
        {
            setManualLock(true)
            DispatchQueue.main.asyncAfter(deadline: .now() + .seconds(seconds)) { [weak self] in
                self?.setManualLock(false)
            }
        }
        #endif
    }

    // MARK: - 派生状态

    var isSessionActive: Bool { session != nil }

    /// 当前番茄阶段(非番茄会话返回 nil)。
    var pomodoroPhase: PomodoroSchedule.Phase? {
        guard let session, let schedule = session.schedule else {
            return nil
        }
        return schedule.phase(elapsed: session.elapsed(at: now))
    }

    var isInPomodoroRest: Bool {
        if case .rest = pomodoroPhase {
            return true
        }
        return false
    }

    /// 番茄专注阶段:承诺不可提前结束,只能等休息窗口。
    var isInPomodoroFocus: Bool {
        if case .focus = pomodoroPhase {
            return true
        }
        return false
    }

    /// 近 7 天强制退出次数,决定冷静期时长与污点提示。
    var recentTaintCount: Int {
        TaintLedger.recentCount(loadTaints(), now: now)
    }

    /// 提前结束前的强制冷静期秒数。
    var exitCooldownSeconds: Int {
        ExitFriction.cooldownSeconds(recentTaintCount: recentTaintCount)
    }

    /// 连续打卡天数(今天或昨天为端点)。
    var streakDays: Int {
        StreakCalculator.streak(records: records, today: now)
    }

    /// 今天是否已有完成记录(用于「今天还未打卡」提示)。
    var hasCompletedToday: Bool {
        records.contains {
            Calendar.current.isDateInToday($0.startedAt) && $0.completed
        }
    }

    /// 主显示时间:倒计时剩余 / 正计时已过 / 番茄当前阶段剩余。
    var primaryTimeText: String {
        guard let session else {
            return DurationFormatter.countdown(0)
        }
        let elapsed = session.elapsed(at: now)
        switch session.mode {
        case .countdown:
            let total = TimeInterval(session.countdownMinutes * 60)
            return DurationFormatter.countdown(total - elapsed)
        case .countUp:
            return DurationFormatter.elapsed(elapsed)
        case .pomodoro:
            switch pomodoroPhase {
            case .focus(_, let remaining), .rest(_, let remaining):
                return DurationFormatter.countdown(remaining)
            default:
                return DurationFormatter.countdown(0)
            }
        }
    }

    /// 圆环进度(正计时无固定终点,按每小时一圈循环)。
    var progress: Double {
        guard let session else {
            return 0
        }
        let elapsed = session.elapsed(at: now)
        switch session.mode {
        case .countdown:
            let total = Double(session.countdownMinutes * 60)
            return min(1, max(0, elapsed / total))
        case .countUp:
            return elapsed.truncatingRemainder(dividingBy: 3600) / 3600
        case .pomodoro:
            guard let schedule = session.schedule else {
                return 0
            }
            switch schedule.phase(elapsed: elapsed) {
            case .focus(_, let remaining):
                return 1 - remaining / schedule.focusSeconds
            case .rest(_, let remaining):
                return 1 - remaining / schedule.breakSeconds
            case .finished:
                return 1
            }
        }
    }

    /// 本次会话累计纯专注秒数(番茄钟不含休息)。
    var sessionFocusSeconds: TimeInterval {
        guard let session else {
            return 0
        }
        return session.focusSeconds(elapsed: session.elapsed(at: now))
    }

    /// 菜单栏标题。存起来而不是算出来,且只在字符串真变化时才回调:
    /// 状态栏项就不会做无谓重排(macOS 26+ 每次重排都要同步向渲染服务器要栅栏)。
    private(set) var statusBarTitle = ""

    /// 标题变化时通知菜单栏项(StatusItemController 订阅)。
    var onStatusBarTitleChange: ((String) -> Void)?

    private func refreshStatusBarTitle() {
        let title = makeStatusBarTitle()
        guard title != statusBarTitle else {
            return
        }
        statusBarTitle = title
        onStatusBarTitleChange?(title)
    }

    private func makeStatusBarTitle() -> String {
        guard let session else {
            return isLockEnabled ? "🔒" : ""
        }
        switch session.mode {
        case .countdown:
            return "⏳ \(primaryTimeText)"
        case .countUp:
            return "⏱ \(primaryTimeText)"
        case .pomodoro:
            switch pomodoroPhase {
            case .rest:
                return "☕ \(primaryTimeText)"
            default:
                return "🍅 \(primaryTimeText)"
            }
        }
    }

    var todayFocusedMinutes: Int {
        records
            .filter { Calendar.current.isDateInToday($0.startedAt) && $0.completed }
            .reduce(0) { $0 + $1.focusedMinutes }
    }

    var todayCompletedSessionCount: Int {
        records.filter {
            Calendar.current.isDateInToday($0.startedAt) && $0.completed
        }.count
    }

    /// 近 days 天逐日专注/质量聚合(趋势图数据源)。
    func dailyFocus(days: Int) -> [DailyFocus] {
        FocusAggregator.dailyTotals(records: records, days: days, today: now)
    }

    // MARK: - 会话控制

    func selectDuration(_ minutes: Int) {
        guard !isSessionActive else {
            return
        }
        selectedMinutes = minutes
    }

    func startSession() {
        guard !isSessionActive else {
            return
        }
        now = Date()
        let schedule: PomodoroSchedule? = selectedMode == .pomodoro
            ? PomodoroSchedule(
                focusMinutes: pomodoroFocusMinutes,
                breakMinutes: pomodoroBreakMinutes,
                rounds: pomodoroRounds
            )
            : nil
        let newSession = ActiveSession(
            mode: selectedMode,
            startedAt: now,
            countdownMinutes: selectedMinutes,
            schedule: schedule,
            title: sessionTitle
        )
        session = newSession
        wasInPomodoroRest = false
        isManualLockOn = false
        sessionInterruptions = 0
        currentUsage = UsageTally()
        blockedNetworkDomains = []
        lastActiveBlocked = nil
        secondsSinceSample = 0
        persistSessionSnapshot(newSession)
        persistManualLock()
        persistInterruptions()
        persistUsage()
        writeHeartbeat(force: true)
        syncLockState()
    }

    /// 提前/手动结束会话。正计时视为正常完成,其余标记未完成。
    func endSessionEarly() {
        guard let session else {
            return
        }
        finishSession(session, completed: session.mode == .countUp)
    }

    func setManualLock(_ enabled: Bool) {
        guard !isSessionActive else {
            return
        }
        isManualLockOn = enabled
        persistManualLock()
        syncLockState()
    }

    /// 用户确认退出应用(输对短语)后的收尾:落记录、清快照,并顺带清理
    /// 旧版 hosts 残留,避免下次启动误判强退。完成后回调(terminateLater 等待)。
    func prepareForConfirmedQuit(completion: @escaping @MainActor () -> Void) {
        if isSessionActive {
            endSessionEarly()
        }
        if isManualLockOn {
            isManualLockOn = false
            persistManualLock()
            syncLockState()
        }
        isQuitting = true
        guard HostsBlocker.hostsContainsBlock() else {
            completion()
            return
        }
        // 移除失败(如取消密码框)也照常退出,下次启动会再清理。
        hostsBlocker.removeBlock { _ in
            completion()
        }
    }

    func dismissTaintNotice() {
        taintNotice = nil
    }

    // MARK: - 定时课程表

    /// 今天下一个尚未开始的时段(用于空闲态提示);未启用/非生效日为 nil。
    var nextScheduledSlot: TimeSlot? {
        TimetableScheduler.nextSlot(after: now, timetable: timetable)
    }

    /// 时段编辑合法性(start<end 且互不重叠),不合法时 UI 显示警告。
    var isTimetableValid: Bool {
        TimetableScheduler.validate(slots: timetable.slots)
    }

    func setTimetableEnabled(_ enabled: Bool) {
        timetable.isEnabled = enabled
        persistTimetable()
    }

    /// 按 id 替换时段并按开始时间重新排序。
    func updateSlot(_ slot: TimeSlot) {
        guard let index = timetable.slots.firstIndex(where: { $0.id == slot.id }) else {
            return
        }
        timetable.slots[index] = slot
        timetable.slots.sort { $0.startMinute < $1.startMinute }
        persistTimetable()
    }

    /// 在最后一个时段之后追加一个 45 分钟的新时段(间隔 10 分钟,不超过午夜)。
    func addSlot() {
        let lastEnd = timetable.slots.map(\.endMinute).max() ?? 9 * 60
        let start = min(lastEnd + 10, 23 * 60)
        let end = min(start + 45, 24 * 60)
        timetable.slots.append(TimeSlot(startMinute: start, endMinute: end))
        timetable.slots.sort { $0.startMinute < $1.startMinute }
        persistTimetable()
    }

    func removeSlot(_ slot: TimeSlot) {
        timetable.slots.removeAll { $0.id == slot.id }
        persistTimetable()
    }

    func toggleWeekday(_ weekday: Int) {
        if timetable.activeWeekdays.contains(weekday) {
            timetable.activeWeekdays.remove(weekday)
        } else {
            timetable.activeWeekdays.insert(weekday)
        }
        persistTimetable()
    }

    func addSkipDate(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard !timetable.skipDates.contains(day) else {
            return
        }
        timetable.skipDates.append(day)
        timetable.skipDates.sort()
        persistTimetable()
    }

    func removeSkipDate(_ date: Date) {
        timetable.skipDates.removeAll { $0 == date }
        persistTimetable()
    }

    func addForceDate(_ date: Date) {
        let day = Calendar.current.startOfDay(for: date)
        guard !timetable.forceDates.contains(day) else {
            return
        }
        timetable.forceDates.append(day)
        timetable.forceDates.sort()
        persistTimetable()
    }

    func removeForceDate(_ date: Date) {
        timetable.forceDates.removeAll { $0 == date }
        persistTimetable()
    }

    // MARK: - 白名单 / 域名 / 记录

    func toggleWhitelist(for app: InstalledApp) {
        guard !isLockEnabled else {
            return
        }
        if whitelist.contains(app.id) {
            whitelist.remove(app.id)
        } else {
            whitelist.insert(app.id)
        }
        persistWhitelist()
        enforcer.updateWhitelist(whitelist)
    }

    /// 锁定期间是否被强制隐藏(即使在白名单)。
    func isForceBlacklisted(_ app: InstalledApp) -> Bool {
        guard let bundleID = app.bundleIdentifier else {
            return false
        }
        return LockPolicy.forcedBlacklistBundleIdentifiers.contains(bundleID)
    }

    /// 添加允许访问的域名;返回 false 表示输入不合法。
    @discardableResult
    func addAllowedDomain(_ raw: String) -> Bool {
        guard !isLockEnabled, let domain = DomainRule.normalize(raw) else {
            return false
        }
        guard !allowedDomains.contains(domain) else {
            return true
        }
        allowedDomains.append(domain)
        allowedDomains.sort()
        persistDomains()
        return true
    }

    func removeAllowedDomain(_ domain: String) {
        guard !isLockEnabled else {
            return
        }
        allowedDomains.removeAll { $0 == domain }
        persistDomains()
    }

    func removeRecord(_ record: FocusRecord) {
        records.removeAll { $0.id == record.id }
        persistRecords()
    }

    func reloadApplications() {
        loadApplications()
    }

    /// 重试清理旧版 hosts 残留块 / 权限修复后重置提示。
    func retryHostsSync() {
        hostsIssue = nil
        browserMonitor.resetPermissionState()
        cleanUpLeftoverHostsBlock()
    }

    /// 导出近 days 天的 Markdown 专注报告到「下载」目录,返回文件 URL。
    func exportReport(days: Int) -> URL? {
        let markdown = FocusReport.markdown(records: records, days: days, today: now)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmm"
        let url = FileManager.default
            .urls(for: .downloadsDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("认真专注报告-近\(days)天-\(formatter.string(from: now)).md")
        do {
            try markdown.write(to: url, atomically: true, encoding: .utf8)
            return url
        } catch {
            return nil
        }
    }

    // MARK: - 内部

    private func tick() {
        now = Date()
        refreshStatusBarTitle()
        sampleUsageIfNeeded()
        guard let session else {
            checkTimetable()
            return
        }
        writeHeartbeat()
        let elapsed = session.elapsed(at: now)

        switch session.mode {
        case .countdown:
            if elapsed >= TimeInterval(session.countdownMinutes * 60) {
                finishSession(session, completed: true)
            }
        case .countUp:
            break
        case .pomodoro:
            guard let schedule = session.schedule else {
                return
            }
            switch schedule.phase(elapsed: elapsed) {
            case .finished:
                finishSession(session, completed: true)
            case .rest:
                if !wasInPomodoroRest {
                    wasInPomodoroRest = true
                    NSSound(named: "Submarine")?.play()
                    syncLockState()
                }
            case .focus:
                if wasInPomodoroRest {
                    wasInPomodoroRest = false
                    NSSound(named: "Ping")?.play()
                    syncLockState()
                }
            }
        }
    }

    /// 空闲时每秒检查课程表:落在生效时段内且当天未结束过 → 自动开启定时专注。
    /// 手动锁定/已有会话时不触发(条件不满足自然顺延,其结束后自动接上)。
    private func checkTimetable() {
        guard
            !isQuitting,
            !isManualLockOn,
            session == nil,
            let slot = TimetableScheduler.currentSlot(at: now, timetable: timetable),
            isTimetableValid
        else {
            return
        }
        let key = TimetableScheduler.dismissKey(slotID: slot.id, on: now)
        guard !dismissedSlotKeys.contains(key) else {
            return
        }
        let remaining = TimetableScheduler.remainingSeconds(in: slot, at: now)
        // 剩余不足 1 分钟不再开启(防止取整后立刻结束的抖动),直接视为当天已处理。
        guard remaining >= 60 else {
            dismissedSlotKeys.insert(key)
            persistDismissedSlots()
            return
        }
        startScheduledSession(slot: slot, remainingSeconds: remaining)
    }

    /// 开启定时专注:倒计时到时段结束(四舍五入到分钟),复用全部倒计时逻辑。
    private func startScheduledSession(slot: TimeSlot, remainingSeconds: Int) {
        let minutes = max(1, Int((Double(remainingSeconds) / 60).rounded()))
        let newSession = ActiveSession(
            mode: .countdown,
            startedAt: now,
            countdownMinutes: minutes,
            schedule: nil,
            title: sessionTitle.isEmpty ? "定时专注 \(slot.rangeText)" : sessionTitle,
            scheduledSlotID: slot.id
        )
        session = newSession
        wasInPomodoroRest = false
        sessionInterruptions = 0
        currentUsage = UsageTally()
        blockedNetworkDomains = []
        lastActiveBlocked = nil
        secondsSinceSample = 0
        persistSessionSnapshot(newSession)
        persistInterruptions()
        persistUsage()
        writeHeartbeat(force: true)
        NSSound(named: "Ping")?.play()
        syncLockState()
    }

    private func finishSession(
        _ session: ActiveSession,
        completed: Bool,
        endedAt: Date = Date(),
        endReason: EndReason? = nil,
        interruptions: Int? = nil
    ) {
        let elapsed = max(0, endedAt.timeIntervalSince(session.startedAt))
        let focusSeconds = session.focusSeconds(elapsed: elapsed)

        let plannedMinutes: Int
        switch session.mode {
        case .countdown:
            plannedMinutes = session.countdownMinutes
        case .countUp:
            plannedMinutes = 0
        case .pomodoro:
            plannedMinutes = Int((session.schedule?.totalFocusSeconds ?? 0) / 60)
        }

        let record = FocusRecord(
            id: UUID(),
            startedAt: session.startedAt,
            endedAt: endedAt,
            mode: session.mode,
            plannedMinutes: plannedMinutes,
            completed: completed,
            focusSeconds: Int(focusSeconds),
            interruptionCount: interruptions ?? sessionInterruptions,
            endReason: endReason ?? (completed ? .completed : .early),
            usage: currentUsage.isEmpty ? nil : currentUsage,
            blockedNetworkDomains: blockedNetworkDomains.isEmpty
                ? nil
                : blockedNetworkDomains.sorted()
        )
        records.insert(record, at: 0)
        persistRecords()

        // 定时会话结束(完成或提前结束):当天该时段不再自动重启。
        if let slotID = session.scheduledSlotID {
            dismissedSlotKeys.insert(TimetableScheduler.dismissKey(slotID: slotID, on: endedAt))
            persistDismissedSlots()
        }

        self.session = nil
        wasInPomodoroRest = false
        sessionInterruptions = 0
        currentUsage = UsageTally()
        blockedNetworkDomains = []
        lastActiveBlocked = nil
        clearSessionSnapshot()
        syncLockState()
        if completed {
            NSSound(named: "Glass")?.play()
        }
    }

    /// 依据 会话阶段 + 手动开关 收敛锁定状态。
    private func syncLockState() {
        let sessionNeedsLock: Bool
        if let session {
            sessionNeedsLock = session.mode != .pomodoro || !isInPomodoroRest
        } else {
            sessionNeedsLock = false
        }
        let desired = isManualLockOn || sessionNeedsLock
        guard desired != isLockEnabled else {
            refreshStatusBarTitle()
            return
        }
        isLockEnabled = desired
        if desired {
            enforcer.start(whitelist: whitelist)
        } else {
            enforcer.stop()
        }
        refreshStatusBarTitle()
    }

    /// 还原 v2.3 可能残留的系统代理改动(异常退出未还原时),成功后清键。
    /// v2.4 起不再接管系统代理,此方法仅用于一次性清理历史残留。
    private func restorePersistedProxySnapshot() {
        guard let data = defaults.data(forKey: Keys.proxySnapshot) else {
            return
        }
        if
            let snapshot = try? JSONDecoder().decode(ProxySnapshot.self, from: data) {
            _ = ProxyConfigurator.restore(snapshot)
        }
        defaults.removeObject(forKey: Keys.proxySnapshot)
    }

    /// 锁定中每 2 秒采样一轮(番茄休息期与未锁定时不执法):
    /// - 前台应用时长在主线程直接记——纯 AppKit 查询,不涉及 Apple 事件,很便宜;
    /// - 浏览器全标签扫描+导离交给后台脚本线程,主线程不等它。
    ///
    /// 曾经这里是同步跑 AppleScript 的,在 macOS 26+ 会把主线程和 WindowServer
    /// 一起拖死(详见 AppleScriptRunner 注释),务必保持异步。
    private func sampleUsageIfNeeded() {
        guard isLockEnabled, !isQuitting else {
            secondsSinceSample = 0
            return
        }
        secondsSinceSample += 1
        guard secondsSinceSample >= BrowserMonitor.sampleInterval else {
            return
        }
        secondsSinceSample = 0

        if
            let frontmost = NSWorkspace.shared.frontmostApplication,
            frontmost.processIdentifier != ProcessInfo.processInfo.processIdentifier
        {
            currentUsage.addApp(
                frontmost.localizedName ?? "未命名应用",
                seconds: BrowserMonitor.sampleInterval
            )
        }
        persistUsageThrottled()

        // 上一轮扫描还没回来就跳过这一轮,不排队堆积。
        guard sweepTask == nil else {
            return
        }
        sweepTask = Task { [weak self] in
            guard let self else {
                return
            }
            let result = await self.browserMonitor.enforce(
                allowedDomains: Set(self.allowedDomains)
            )
            self.sweepTask = nil
            self.applySweepResult(result)
        }
    }

    /// 合并一轮浏览器扫描结果(回到主线程后调用)。
    private func applySweepResult(_ result: BrowserMonitor.SweepResult) {
        guard isLockEnabled, !isQuitting else {
            return
        }
        blockedNetworkDomains.formUnion(result.blockedDomains)
        if let allowed = result.activeAllowed {
            currentUsage.addSite(allowed, seconds: BrowserMonitor.sampleInterval)
        }
        // 前台活动标签命中非白名单:相对上次变化时计一次分心 + 横幅(去抖)。
        if let active = result.activeBlocked {
            if active != lastActiveBlocked {
                lastActiveBlocked = active
                registerBlocked(active)
            }
        } else {
            lastActiveBlocked = nil
        }
    }

    private func registerBlocked(_ appName: String) {
        if session != nil {
            sessionInterruptions += 1
            persistInterruptions()
        }
        showBlockedBanner(appName)
    }

    private func showBlockedBanner(_ appName: String) {
        blockedBannerTask?.cancel()
        blockedAppName = appName
        blockedBannerTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else {
                return
            }
            self?.blockedAppName = nil
        }
    }

    // MARK: - 强退恢复

    /// 启动时检查遗留状态:上次未优雅退出(会话快照或手动锁定标记还在)
    /// → 记污点,并恢复会话/锁定或补记强退记录。
    private func recoverFromAbnormalTermination() {
        let leftoverSession = loadSessionSnapshot()
        let leftoverManualLock = defaults.bool(forKey: Keys.manualLock)

        guard leftoverSession != nil || leftoverManualLock else {
            // 无遗留锁定状态;清理可能残留的系统代理与 hosts 块。
            restorePersistedProxySnapshot()
            cleanUpLeftoverHostsBlock()
            return
        }

        now = Date()
        recordTaint(at: now)

        if let leftoverSession {
            let heartbeat = defaults.object(forKey: Keys.heartbeat) as? Date
            let interruptions = defaults.integer(forKey: Keys.interruptions)
            currentUsage = loadUsage()
            switch RecoveryDecision.decide(
                session: leftoverSession,
                lastHeartbeat: heartbeat,
                now: now
            ) {
            case .resume(let resumed):
                session = resumed
                sessionInterruptions = interruptions
                blockedNetworkDomains = []
                lastActiveBlocked = nil
                wasInPomodoroRest = false
                isManualLockOn = false
                persistManualLock()
                writeHeartbeat(force: true)
                taintNotice = TaintNotice(occurredAt: heartbeat ?? resumed.startedAt, recentCount: recentTaintCount)
                restorePersistedProxySnapshot()
                syncLockState()
                cleanUpLeftoverHostsBlock()
            case .finalize(let endedAt, _):
                // focusSeconds 由 finishSession 按 endedAt 重新推算,结果一致
                finishSession(
                    leftoverSession,
                    completed: false,
                    endedAt: endedAt,
                    endReason: .forceQuit,
                    interruptions: interruptions
                )
                taintNotice = TaintNotice(occurredAt: endedAt, recentCount: recentTaintCount)
                restorePersistedProxySnapshot()
                cleanUpLeftoverHostsBlock()
            }
        } else {
            // 手动锁定没有时间窗口,无条件恢复(只有短语能关)。
            isManualLockOn = true
            taintNotice = TaintNotice(occurredAt: now, recentCount: recentTaintCount)
            restorePersistedProxySnapshot()
            syncLockState()
            cleanUpLeftoverHostsBlock()
        }
    }

    /// 若 /etc/hosts 残留旧版屏蔽块则尝试移除(v2.1 遗留迁移)。
    private func cleanUpLeftoverHostsBlock() {
        guard HostsBlocker.hostsContainsBlock() else {
            return
        }
        hostsBlocker.removeBlock { [weak self] success in
            if !success {
                self?.hostsIssue = .removeFailed
            }
        }
    }

    private func recordTaint(at date: Date) {
        var taints = loadTaints()
        taints.append(date)
        taints = TaintLedger.pruned(taints, now: date)
        defaults.set(taints, forKey: Keys.taints)
    }

    private func loadTaints() -> [Date] {
        defaults.array(forKey: Keys.taints) as? [Date] ?? []
    }

    // MARK: - 持久化

    private func writeHeartbeat(force: Bool = false) {
        guard force || now.timeIntervalSince(lastHeartbeatWrite) >= Self.heartbeatInterval else {
            return
        }
        lastHeartbeatWrite = now
        defaults.set(now, forKey: Keys.heartbeat)
    }

    private func persistSessionSnapshot(_ session: ActiveSession) {
        if let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: Keys.session)
        }
    }

    private func clearSessionSnapshot() {
        defaults.removeObject(forKey: Keys.session)
        defaults.removeObject(forKey: Keys.heartbeat)
        defaults.removeObject(forKey: Keys.interruptions)
        defaults.removeObject(forKey: Keys.usage)
    }

    private func loadSessionSnapshot() -> ActiveSession? {
        guard let data = defaults.data(forKey: Keys.session) else {
            return nil
        }
        return try? JSONDecoder().decode(ActiveSession.self, from: data)
    }

    private func persistManualLock() {
        defaults.set(isManualLockOn, forKey: Keys.manualLock)
    }

    private func persistInterruptions() {
        defaults.set(sessionInterruptions, forKey: Keys.interruptions)
    }

    private func persistDomains() {
        defaults.set(allowedDomains, forKey: Keys.allowedDomains)
    }

    private func persistTimetable() {
        if let data = try? JSONEncoder().encode(timetable) {
            defaults.set(data, forKey: Keys.timetable)
        }
    }

    private static func loadTimetable(from defaults: UserDefaults) -> FocusTimetable {
        guard
            let data = defaults.data(forKey: Keys.timetable),
            let decoded = try? JSONDecoder().decode(FocusTimetable.self, from: data)
        else {
            return .default
        }
        return decoded
    }

    private func persistDismissedSlots() {
        defaults.set(Array(dismissedSlotKeys), forKey: Keys.dismissedSlots)
    }

    /// 加载「今天已结束」的时段键,顺手丢弃隔日旧键(避免无限增长)。
    private static func loadDismissedSlotKeys(
        from defaults: UserDefaults,
        today: Date
    ) -> Set<String> {
        let stored = defaults.stringArray(forKey: Keys.dismissedSlots) ?? []
        let kept = stored.filter { TimetableScheduler.keyIsForDay($0, date: today) }
        if kept.count != stored.count {
            defaults.set(kept, forKey: Keys.dismissedSlots)
        }
        return Set(kept)
    }

    private var lastUsageWrite = Date.distantPast

    /// usage 随心跳节奏节流写入(采样每 2s 一次,逐次写 defaults 太频)。
    private func persistUsageThrottled() {
        guard now.timeIntervalSince(lastUsageWrite) >= Self.heartbeatInterval else {
            return
        }
        persistUsage()
    }

    private func persistUsage() {
        lastUsageWrite = now
        if currentUsage.isEmpty {
            defaults.removeObject(forKey: Keys.usage)
        } else if let data = try? JSONEncoder().encode(currentUsage) {
            defaults.set(data, forKey: Keys.usage)
        }
    }

    private func loadUsage() -> UsageTally {
        guard
            let data = defaults.data(forKey: Keys.usage),
            let decoded = try? JSONDecoder().decode(UsageTally.self, from: data)
        else {
            return UsageTally()
        }
        return decoded
    }

    private func loadApplications() {
        isLoadingApps = true
        Task.detached(priority: .userInitiated) {
            let apps = AppScanner.installedApps()
            await MainActor.run {
                self.installedApps = apps
                self.isLoadingApps = false
            }
        }
    }

    private func persistWhitelist() {
        defaults.set(Array(whitelist).sorted(), forKey: Keys.whitelist)
    }

    private func persistRecords() {
        let trimmed = Array(records.prefix(200))
        records = trimmed
        if let data = try? JSONEncoder().encode(trimmed) {
            defaults.set(data, forKey: Keys.records)
        }
    }

    /// 读取 v2 记录;首次运行时从旧版 v1 迁移(旧记录均为倒计时模式)。
    private static func loadRecords(from defaults: UserDefaults) -> [FocusRecord] {
        if
            let data = defaults.data(forKey: Keys.records),
            let decoded = try? JSONDecoder().decode([FocusRecord].self, from: data)
        {
            return decoded
        }
        if
            let legacyData = defaults.data(forKey: Keys.legacyRecords),
            let legacy = try? JSONDecoder().decode([LegacyFocusRecord].self, from: legacyData)
        {
            let migrated = legacy.map(\.migrated)
            if let data = try? JSONEncoder().encode(migrated) {
                defaults.set(data, forKey: Keys.records)
            }
            return migrated
        }
        return []
    }

    deinit {
        clockTimer?.invalidate()
        blockedBannerTask?.cancel()
        sweepTask?.cancel()
    }
}
