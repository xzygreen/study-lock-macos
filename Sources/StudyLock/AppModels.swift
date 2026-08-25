import AppKit
import Foundation

struct InstalledApp: Identifiable, Hashable {
    let id: String
    let name: String
    let bundleIdentifier: String?
    let url: URL

    var icon: NSImage {
        NSWorkspace.shared.icon(forFile: url.path)
    }
}

enum FocusMode: String, Codable, CaseIterable, Identifiable {
    case countdown
    case countUp
    case pomodoro

    var id: String { rawValue }

    var title: String {
        switch self {
        case .countdown: "倒计时"
        case .countUp: "正计时"
        case .pomodoro: "番茄钟"
        }
    }

    var symbol: String {
        switch self {
        case .countdown: "timer"
        case .countUp: "stopwatch"
        case .pomodoro: "circle.grid.2x2"
        }
    }
}

/// 会话结束原因(v2.1 起记录)。
enum EndReason: String, Codable {
    case completed
    case early
    case forceQuit
}

struct FocusRecord: Codable, Identifiable, Equatable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let mode: FocusMode
    let plannedMinutes: Int
    let completed: Bool
    /// 纯专注秒数(番茄钟不含休息)。nil 时按起止时间推算。
    let focusSeconds: Int?
    /// 会话内拦截非白名单应用的次数(v2.1 前的旧记录为 nil)。
    let interruptionCount: Int?
    /// 结束原因(v2.1 前的旧记录为 nil)。
    let endReason: EndReason?
    /// 专注期间应用/网站使用时长(v2.2 前的旧记录为 nil)。
    let usage: UsageTally?
    /// 被网络门禁拦截的域名(去重;v2.3 前的旧记录为 nil)。
    let blockedNetworkDomains: [String]?

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        mode: FocusMode,
        plannedMinutes: Int,
        completed: Bool,
        focusSeconds: Int?,
        interruptionCount: Int? = nil,
        endReason: EndReason? = nil,
        usage: UsageTally? = nil,
        blockedNetworkDomains: [String]? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.mode = mode
        self.plannedMinutes = plannedMinutes
        self.completed = completed
        self.focusSeconds = focusSeconds
        self.interruptionCount = interruptionCount
        self.endReason = endReason
        self.usage = usage
        self.blockedNetworkDomains = blockedNetworkDomains
    }

    var focusedMinutes: Int {
        if let focusSeconds {
            return max(1, focusSeconds / 60)
        }
        return max(1, Int(endedAt.timeIntervalSince(startedAt) / 60))
    }

    /// 专注质量分;旧记录(无结束原因)为 nil。
    var qualityScore: Int? {
        guard let endReason else {
            return nil
        }
        return FocusQuality.score(
            interruptions: interruptionCount ?? 0,
            endReason: endReason
        )
    }
}

/// v1 记录(旧版 records.v1,无 mode 字段),仅用于迁移。
struct LegacyFocusRecord: Codable {
    let id: UUID
    let startedAt: Date
    let endedAt: Date
    let plannedMinutes: Int
    let completed: Bool

    var migrated: FocusRecord {
        FocusRecord(
            id: id,
            startedAt: startedAt,
            endedAt: endedAt,
            mode: .countdown,
            plannedMinutes: plannedMinutes,
            completed: completed,
            focusSeconds: nil
        )
    }
}

/// 番茄钟排程:专注 f 分 → 休息 b 分,循环 n 轮,最后一轮专注结束即完成(无尾休息)。
struct PomodoroSchedule: Equatable, Codable {
    let focusMinutes: Int
    let breakMinutes: Int
    let rounds: Int

    enum Phase: Equatable {
        case focus(round: Int, remaining: TimeInterval)
        case rest(round: Int, remaining: TimeInterval)
        case finished
    }

    var focusSeconds: TimeInterval { TimeInterval(focusMinutes * 60) }
    var breakSeconds: TimeInterval { TimeInterval(breakMinutes * 60) }
    var cycleSeconds: TimeInterval { focusSeconds + breakSeconds }

    /// 总时长 = n×专注 + (n-1)×休息
    var totalSeconds: TimeInterval {
        TimeInterval(rounds) * focusSeconds + TimeInterval(rounds - 1) * breakSeconds
    }

    var totalFocusSeconds: TimeInterval {
        TimeInterval(rounds) * focusSeconds
    }

    func phase(elapsed: TimeInterval) -> Phase {
        guard elapsed < totalSeconds else {
            return .finished
        }
        let clamped = max(0, elapsed)
        let round = Int(clamped / cycleSeconds)
        let position = clamped - TimeInterval(round) * cycleSeconds
        if position < focusSeconds {
            return .focus(round: round + 1, remaining: focusSeconds - position)
        }
        return .rest(round: round + 1, remaining: cycleSeconds - position)
    }

    /// 到 elapsed 为止累计的纯专注秒数(不含休息)。
    func focusedSeconds(elapsed: TimeInterval) -> TimeInterval {
        guard elapsed > 0 else {
            return 0
        }
        guard elapsed < totalSeconds else {
            return totalFocusSeconds
        }
        let round = Int(elapsed / cycleSeconds)
        let position = elapsed - TimeInterval(round) * cycleSeconds
        return TimeInterval(round) * focusSeconds + min(position, focusSeconds)
    }
}

/// 进行中的专注会话。所有派生量(剩余、已专注、阶段)由 startedAt 和当前时间实时计算,
/// 不依赖计数器,系统休眠后依然准确。Codable 用于崩溃/强退后的会话恢复。
struct ActiveSession: Equatable, Codable {
    let mode: FocusMode
    let startedAt: Date
    let countdownMinutes: Int
    let schedule: PomodoroSchedule?
    let title: String
    /// 由定时课程表自动开启时,记录来源时段 id;手动会话为 nil。
    /// 旧版快照无此字段,解码时按 nil 处理(向后兼容)。
    let scheduledSlotID: UUID?

    init(
        mode: FocusMode,
        startedAt: Date,
        countdownMinutes: Int,
        schedule: PomodoroSchedule?,
        title: String,
        scheduledSlotID: UUID? = nil
    ) {
        self.mode = mode
        self.startedAt = startedAt
        self.countdownMinutes = countdownMinutes
        self.schedule = schedule
        self.title = title
        self.scheduledSlotID = scheduledSlotID
    }

    enum CodingKeys: String, CodingKey {
        case mode, startedAt, countdownMinutes, schedule, title, scheduledSlotID
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        mode = try container.decode(FocusMode.self, forKey: .mode)
        startedAt = try container.decode(Date.self, forKey: .startedAt)
        countdownMinutes = try container.decode(Int.self, forKey: .countdownMinutes)
        schedule = try container.decodeIfPresent(PomodoroSchedule.self, forKey: .schedule)
        title = try container.decode(String.self, forKey: .title)
        scheduledSlotID = try container.decodeIfPresent(UUID.self, forKey: .scheduledSlotID)
    }

    func elapsed(at now: Date) -> TimeInterval {
        max(0, now.timeIntervalSince(startedAt))
    }

    /// 按 elapsed 计算纯专注秒数(番茄钟不含休息,倒计时封顶计划时长)。
    func focusSeconds(elapsed: TimeInterval) -> TimeInterval {
        if let schedule {
            return schedule.focusedSeconds(elapsed: elapsed)
        }
        if mode == .countdown {
            return min(elapsed, TimeInterval(countdownMinutes * 60))
        }
        return elapsed
    }

    /// 计划结束时间(正计时无终点,返回 nil)。
    var plannedEnd: Date? {
        switch mode {
        case .countdown:
            return startedAt.addingTimeInterval(TimeInterval(countdownMinutes * 60))
        case .countUp:
            return nil
        case .pomodoro:
            guard let schedule else {
                return startedAt
            }
            return startedAt.addingTimeInterval(schedule.totalSeconds)
        }
    }
}

/// 启动时对遗留会话(上次异常终止)的处置决策。
enum RecoveryDecision: Equatable {
    /// 仍在计划窗口内,恢复会话继续锁定。
    case resume(ActiveSession)
    /// 窗口已过或心跳过期,按 endedAt 补记一条强退记录。
    case finalize(endedAt: Date, focusSeconds: Int)

    /// 心跳宽限:最后心跳距今超过该值,视为早已退出,按心跳时间结算。
    static let heartbeatGrace: TimeInterval = 10 * 60

    static func decide(
        session: ActiveSession,
        lastHeartbeat: Date?,
        now: Date
    ) -> RecoveryDecision {
        let heartbeat = max(session.startedAt, lastHeartbeat ?? session.startedAt)
        if now.timeIntervalSince(heartbeat) > heartbeatGrace {
            return finalized(session, at: heartbeat)
        }
        guard let plannedEnd = session.plannedEnd else {
            return .resume(session)
        }
        return now < plannedEnd ? .resume(session) : finalized(session, at: heartbeat)
    }

    private static func finalized(_ session: ActiveSession, at endedAt: Date) -> RecoveryDecision {
        let elapsed = max(0, endedAt.timeIntervalSince(session.startedAt))
        return .finalize(
            endedAt: endedAt,
            focusSeconds: Int(session.focusSeconds(elapsed: elapsed))
        )
    }
}

/// 强制退出「污点」台账:只统计近 retentionDays 天。
enum TaintLedger {
    static let retentionDays = 7

    static func pruned(_ taints: [Date], now: Date) -> [Date] {
        let cutoff = now.addingTimeInterval(-TimeInterval(retentionDays * 24 * 3600))
        return taints.filter { $0 > cutoff }
    }

    static func recentCount(_ taints: [Date], now: Date) -> Int {
        pruned(taints, now: now).count
    }
}

/// 退出摩擦力参数。
enum ExitFriction {
    /// 点「提前结束」后的强制冷静期秒数,近 7 天强退次数越多越长。
    static func cooldownSeconds(recentTaintCount: Int) -> Int {
        switch recentTaintCount {
        case ..<1: return 10
        case 1: return 20
        case 2: return 30
        default: return 60
        }
    }
}

/// 专注质量分:基础 100,每次拦截 −8,提前结束 −25,强制退出 −50,下限 0。
enum FocusQuality {
    static func score(interruptions: Int, endReason: EndReason) -> Int {
        var score = 100 - interruptions * 8
        switch endReason {
        case .completed:
            break
        case .early:
            score -= 25
        case .forceQuit:
            score -= 50
        }
        return max(0, score)
    }
}

/// 连续打卡统计。
enum StreakCalculator {
    /// 以今天(或今天尚无完成记录时以昨天)为端点,连续每天都有完成记录的天数。
    static func streak(
        records: [FocusRecord],
        today: Date,
        calendar: Calendar = .current
    ) -> Int {
        let completedDays = Set(
            records.filter(\.completed).map { calendar.startOfDay(for: $0.startedAt) }
        )
        guard !completedDays.isEmpty else {
            return 0
        }
        var day = calendar.startOfDay(for: today)
        if !completedDays.contains(day) {
            guard
                let yesterday = calendar.date(byAdding: .day, value: -1, to: day),
                completedDays.contains(yesterday)
            else {
                return 0
            }
            day = yesterday
        }
        var count = 0
        while completedDays.contains(day) {
            count += 1
            guard let previous = calendar.date(byAdding: .day, value: -1, to: day) else {
                break
            }
            day = previous
        }
        return count
    }

    /// 最近一次完成记录所在日(startOfDay);无完成记录为 nil。
    static func lastCompletionDay(
        records: [FocusRecord],
        calendar: Calendar = .current
    ) -> Date? {
        records
            .filter(\.completed)
            .map { calendar.startOfDay(for: $0.startedAt) }
            .max()
    }
}

/// 按日聚合的专注量,用于趋势图。
struct DailyFocus: Identifiable, Equatable {
    /// startOfDay
    let day: Date
    /// 当日已完成会话的纯专注分钟合计。
    let focusedMinutes: Int
    /// 当日有质量数据的会话平均质量分;无则为 nil。
    let averageQuality: Int?

    var id: Date { day }
}

enum FocusAggregator {
    /// 近 days 天(含 today)逐日聚合,无记录的日子补 0,按时间升序返回。
    static func dailyTotals(
        records: [FocusRecord],
        days: Int,
        today: Date,
        calendar: Calendar = .current
    ) -> [DailyFocus] {
        let todayStart = calendar.startOfDay(for: today)
        var byDay: [Date: (minutes: Int, scores: [Int])] = [:]
        for record in records {
            let day = calendar.startOfDay(for: record.startedAt)
            var bucket = byDay[day] ?? (0, [])
            if record.completed {
                bucket.minutes += record.focusedMinutes
            }
            if let score = record.qualityScore {
                bucket.scores.append(score)
            }
            byDay[day] = bucket
        }
        return (0..<max(0, days)).reversed().compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: -offset, to: todayStart) else {
                return nil
            }
            let bucket = byDay[day] ?? (0, [])
            let average = bucket.scores.isEmpty
                ? nil
                : bucket.scores.reduce(0, +) / bucket.scores.count
            return DailyFocus(
                day: day,
                focusedMinutes: bucket.minutes,
                averageQuality: average
            )
        }
    }
}

enum AppIdentity {
    static func key(bundleIdentifier: String?, bundleURL: URL?) -> String? {
        if let bundleIdentifier, !bundleIdentifier.isEmpty {
            return bundleIdentifier
        }
        if let bundleURL {
            return "path:\(bundleURL.standardizedFileURL.path)"
        }
        return nil
    }
}

enum LockPolicy {
    static let protectedBundleIdentifiers: Set<String> = [
        "com.apple.finder",
        "com.apple.dock",
        "com.apple.SystemUIServer",
        "com.apple.controlcenter",
        "com.apple.notificationcenterui",
        "com.apple.loginwindow",
        "com.apple.WindowManager",
        "com.apple.Spotlight",
        "com.apple.CoreServicesUIAgent",
        "com.apple.SecurityAgent",
        "com.apple.UserNotificationCenter",
        "com.apple.TextInputMenuAgent"
    ]

    /// 锁定期间强制隐藏,即使在白名单中(防止去系统设置关权限/杀进程)。
    static let forcedBlacklistBundleIdentifiers: Set<String> = [
        "com.apple.systempreferences",
        "com.apple.ActivityMonitor"
    ]

    static func allows(
        bundleIdentifier: String?,
        bundleURL: URL?,
        processIdentifier: pid_t,
        ownProcessIdentifier: pid_t,
        whitelist: Set<String>
    ) -> Bool {
        if processIdentifier == ownProcessIdentifier {
            return true
        }
        if let bundleIdentifier, forcedBlacklistBundleIdentifiers.contains(bundleIdentifier) {
            return false
        }
        if let bundleIdentifier, protectedBundleIdentifiers.contains(bundleIdentifier) {
            return true
        }
        guard let key = AppIdentity.key(
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL
        ) else {
            return true
        }
        return whitelist.contains(key)
    }
}

/// 屏蔽域名的规范化与校验。
enum DomainRule {
    /// 把用户输入(可能是完整 URL)规范化为裸域名;不合法返回 nil。
    static func normalize(_ raw: String) -> String? {
        var domain = raw
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if let schemeRange = domain.range(of: "://") {
            domain = String(domain[schemeRange.upperBound...])
        }
        if let slash = domain.firstIndex(of: "/") {
            domain = String(domain[..<slash])
        }
        if let query = domain.firstIndex(of: "?") {
            domain = String(domain[..<query])
        }
        if let colon = domain.firstIndex(of: ":") {
            domain = String(domain[..<colon])
        }
        if domain.hasPrefix("www.") {
            domain.removeFirst(4)
        }
        guard
            domain.contains("."),
            !domain.hasPrefix("."),
            !domain.hasSuffix("."),
            !domain.hasPrefix("-"),
            !domain.hasSuffix("-"),
            domain.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" })
        else {
            return nil
        }
        return domain
    }

    /// 域名是否被白名单允许:精确匹配或作为白名单项的子域
    /// (docs.foo.com 匹配 foo.com;notfoo.com 不匹配)。空白名单一律不允许。
    static func isAllowed(_ domain: String, whitelist: Set<String>) -> Bool {
        whitelist.contains { allowed in
            domain == allowed || domain.hasSuffix("." + allowed)
        }
    }
}

/// 单个网络服务的代理设置快照(用于锁定接管前保存、解锁/崩溃后还原)。
struct ProxyServiceSnapshot: Codable, Equatable {
    let serviceName: String
    var webProxyEnabled: Bool
    var webProxyHost: String
    var webProxyPort: Int
    var secureWebProxyEnabled: Bool
    var secureWebProxyHost: String
    var secureWebProxyPort: Int
    var autoProxyURL: String
    var autoProxyEnabled: Bool

    /// 原上游 HTTP 代理(host, port);未启用为 nil。
    var upstream: (host: String, port: Int)? {
        guard webProxyEnabled, !webProxyHost.isEmpty, webProxyPort > 0 else {
            return nil
        }
        return (webProxyHost, webProxyPort)
    }
}

struct ProxySnapshot: Codable, Equatable {
    let services: [ProxyServiceSnapshot]

    /// 任一服务已配置的上游代理(用于链式转发)。
    var upstream: (host: String, port: Int)? {
        for service in services {
            if let upstream = service.upstream {
                return upstream
            }
        }
        return nil
    }
}

/// 已知可脚本化浏览器及其 AppleScript 方言。
enum BrowserPolicy {
    enum Dialect {
        case safari
        case chromium
    }

    /// bundle id → 方言。Safari 系与 Chromium 系(各发行渠道的 AppleScript 接口一致)。
    static let browsers: [String: Dialect] = [
        "com.apple.Safari": .safari,
        "com.apple.SafariTechnologyPreview": .safari,
        "com.google.Chrome": .chromium,
        "com.google.Chrome.beta": .chromium,
        "com.google.Chrome.dev": .chromium,
        "com.google.Chrome.canary": .chromium,
        "org.chromium.Chromium": .chromium,
        "com.microsoft.edgemac": .chromium,
        "com.microsoft.edgemac.Beta": .chromium,
        "com.microsoft.edgemac.Dev": .chromium,
        "com.microsoft.edgemac.Canary": .chromium,
        "company.thebrowser.Browser": .chromium,
        "com.brave.Browser": .chromium,
        "com.brave.Browser.beta": .chromium,
        "com.brave.Browser.nightly": .chromium,
        "com.vivaldi.Vivaldi": .chromium
    ]

    static func dialect(for bundleIdentifier: String?) -> Dialect? {
        guard let bundleIdentifier else {
            return nil
        }
        return browsers[bundleIdentifier]
    }

    static func isBrowser(_ bundleIdentifier: String?) -> Bool {
        dialect(for: bundleIdentifier) != nil
    }
}

/// 会话内应用/网站使用时长(秒)累计。
struct UsageTally: Codable, Equatable {
    var apps: [String: Int] = [:]
    var sites: [String: Int] = [:]

    var isEmpty: Bool { apps.isEmpty && sites.isEmpty }

    mutating func addApp(_ name: String, seconds: Int) {
        apps[name, default: 0] += seconds
    }

    mutating func addSite(_ domain: String, seconds: Int) {
        sites[domain, default: 0] += seconds
    }

    /// 时长降序;同长按名称稳定排序。
    var topApps: [(name: String, seconds: Int)] {
        apps.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { (name: $0.key, seconds: $0.value) }
    }

    var topSites: [(name: String, seconds: Int)] {
        sites.sorted { ($1.value, $0.key) < ($0.value, $1.key) }
            .map { (name: $0.key, seconds: $0.value) }
    }

    /// 合并(用于跨会话汇总)。
    func merging(_ other: UsageTally) -> UsageTally {
        var result = self
        for (app, seconds) in other.apps {
            result.addApp(app, seconds: seconds)
        }
        for (site, seconds) in other.sites {
            result.addSite(site, seconds: seconds)
        }
        return result
    }
}

/// 导出用 Markdown 专注报告(纯函数)。
enum FocusReport {
    static func markdown(
        records: [FocusRecord],
        days: Int,
        today: Date,
        calendar: Calendar = .current
    ) -> String {
        let cutoff = calendar.date(
            byAdding: .day,
            value: -(days - 1),
            to: calendar.startOfDay(for: today)
        ) ?? today
        let ranged = records
            .filter { $0.startedAt >= cutoff }
            .sorted { $0.startedAt < $1.startedAt }

        let completed = ranged.filter(\.completed)
        let totalMinutes = completed.reduce(0) { $0 + $1.focusedMinutes }
        let scores = ranged.compactMap(\.qualityScore)
        let averageQuality = scores.isEmpty ? nil : scores.reduce(0, +) / scores.count
        let interruptions = ranged.reduce(0) { $0 + ($1.interruptionCount ?? 0) }
        let forceQuits = ranged.filter { $0.endReason == .forceQuit }.count
        let streak = StreakCalculator.streak(records: records, today: today, calendar: calendar)
        let combinedUsage = ranged
            .compactMap(\.usage)
            .reduce(UsageTally()) { $0.merging($1) }

        var lines: [String] = []
        lines.append("# 认真 · 专注报告(近 \(days) 天)")
        lines.append("")
        lines.append("生成时间:\(dateTimeText(today))")
        lines.append("")
        lines.append("## 总览")
        lines.append("")
        lines.append("| 指标 | 数值 |")
        lines.append("| --- | --- |")
        lines.append("| 完成专注 | \(completed.count) 次 / \(totalMinutes) 分钟 |")
        lines.append("| 未完成会话 | \(ranged.count - completed.count) 次(其中强制退出 \(forceQuits) 次)|")
        lines.append("| 平均质量分 | \(averageQuality.map(String.init) ?? "—") |")
        lines.append("| 分心拦截 | \(interruptions) 次 |")
        lines.append("| 连续打卡 | \(streak) 天 |")

        let daily = FocusAggregator.dailyTotals(
            records: records,
            days: days,
            today: today,
            calendar: calendar
        )
        lines.append("")
        lines.append("## 逐日专注")
        lines.append("")
        lines.append("| 日期 | 专注分钟 | 平均质量 |")
        lines.append("| --- | ---: | ---: |")
        for item in daily {
            lines.append(
                "| \(dayText(item.day)) | \(item.focusedMinutes) |"
                    + " \(item.averageQuality.map(String.init) ?? "—") |"
            )
        }

        if !combinedUsage.isEmpty {
            lines.append("")
            lines.append("## 使用时长汇总(专注期间)")
            appendUsageSection(&lines, title: "应用", entries: combinedUsage.topApps)
            appendUsageSection(&lines, title: "网站", entries: combinedUsage.topSites)
        }

        lines.append("")
        lines.append("## 会话明细")
        if ranged.isEmpty {
            lines.append("")
            lines.append("(区间内无记录)")
        }
        for record in ranged.reversed() {
            lines.append("")
            lines.append("### \(dateTimeText(record.startedAt)) · \(record.mode.title)")
            lines.append("")
            var summary = "\(statusText(record)),专注 \(record.focusedMinutes) 分钟"
            if let score = record.qualityScore {
                summary += ",质量 \(score)"
            }
            if let count = record.interruptionCount, count > 0 {
                summary += ",拦截 \(count) 次"
            }
            lines.append("- \(summary)")
            if let usage = record.usage, !usage.isEmpty {
                for (name, seconds) in usage.topApps.prefix(3) {
                    lines.append("- 应用 \(name):\(durationText(seconds))")
                }
                for (name, seconds) in usage.topSites.prefix(3) {
                    lines.append("- 网站 \(name):\(durationText(seconds))")
                }
            }
            if let blocked = record.blockedNetworkDomains, !blocked.isEmpty {
                let shown = blocked.prefix(8).joined(separator: "、")
                let suffix = blocked.count > 8 ? " 等 \(blocked.count) 个" : ""
                lines.append("- 被拦网站:\(shown)\(suffix)")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func appendUsageSection(
        _ lines: inout [String],
        title: String,
        entries: [(name: String, seconds: Int)]
    ) {
        guard !entries.isEmpty else {
            return
        }
        lines.append("")
        lines.append("### \(title)")
        lines.append("")
        lines.append("| \(title) | 时长 |")
        lines.append("| --- | ---: |")
        for (name, seconds) in entries {
            lines.append("| \(name) | \(durationText(seconds)) |")
        }
    }

    private static func statusText(_ record: FocusRecord) -> String {
        if record.completed {
            return "完成"
        }
        return record.endReason == .forceQuit ? "强制退出" : "提前结束"
    }

    static func durationText(_ seconds: Int) -> String {
        if seconds >= 3600 {
            return "\(seconds / 3600) 小时 \(seconds % 3600 / 60) 分钟"
        }
        if seconds >= 60 {
            return "\(seconds / 60) 分钟"
        }
        return "\(seconds) 秒"
    }

    private static func dayText(_ date: Date) -> String {
        dayFormatter.string(from: date)
    }

    private static func dateTimeText(_ date: Date) -> String {
        dateTimeFormatter.string(from: date)
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter
    }()
}

/// /etc/hosts 标记块的纯文本变换(幂等,可单测;实际写入见 HostsBlocker)。
enum HostsFileEditor {
    static let beginMarker = "# >>> StudyLock focus block >>>"
    static let endMarker = "# <<< StudyLock focus block <<<"

    /// 每个域名展开为 IPv4/IPv6 × 裸域/www 四条记录。
    static func entries(for domains: [String]) -> [String] {
        domains.flatMap { domain in
            [
                "127.0.0.1\t\(domain)",
                "127.0.0.1\twww.\(domain)",
                "::1\t\(domain)",
                "::1\twww.\(domain)"
            ]
        }
    }

    static func containsBlock(_ contents: String) -> Bool {
        contents
            .components(separatedBy: "\n")
            .contains { $0.trimmingCharacters(in: .whitespaces) == beginMarker }
    }

    /// 删除我们的标记块(含标记行);容忍多个块与孤立标记。
    static func removingBlock(from contents: String) -> String {
        var kept: [String] = []
        var inBlock = false
        for line in contents.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == beginMarker {
                inBlock = true
                continue
            }
            if trimmed == endMarker {
                inBlock = false
                continue
            }
            if !inBlock {
                kept.append(line)
            }
        }
        while kept.last?.isEmpty == true {
            kept.removeLast()
        }
        guard !kept.isEmpty else {
            return ""
        }
        return kept.joined(separator: "\n") + "\n"
    }

    /// 先剥离旧块再在文件末尾插入新块(幂等)。域名为空等价于纯移除。
    static func inserting(domains: [String], into contents: String) -> String {
        let stripped = removingBlock(from: contents)
        guard !domains.isEmpty else {
            return stripped
        }
        var result = stripped
        if !result.isEmpty, !result.hasSuffix("\n") {
            result += "\n"
        }
        result += beginMarker + "\n"
        result += entries(for: domains).joined(separator: "\n") + "\n"
        result += endMarker + "\n"
        return result
    }
}

enum DurationFormatter {
    /// 倒计时:向上取整,mm:ss(超过一小时为 h:mm:ss)。
    static func countdown(_ interval: TimeInterval) -> String {
        format(seconds: max(0, Int(interval.rounded(.up))))
    }

    /// 正计时:向下取整,mm:ss(超过一小时为 h:mm:ss)。
    static func elapsed(_ interval: TimeInterval) -> String {
        format(seconds: max(0, Int(interval.rounded(.down))))
    }

    private static func format(seconds: Int) -> String {
        if seconds >= 3600 {
            return String(
                format: "%d:%02d:%02d",
                seconds / 3600,
                (seconds % 3600) / 60,
                seconds % 60
            )
        }
        return String(format: "%02d:%02d", seconds / 60, seconds % 60)
    }
}

/// 提前解除锁定所需的确认短语:动态生成(时间 + 已专注分钟 + 随机尾句),
/// 防止肌肉记忆秒退。
enum ExitConfirmation {
    static let closingLines = [
        "拖延不会让任务消失",
        "我清楚自己在逃避什么",
        "这次半途而废由我自己负责",
        "刷手机换不来心里踏实",
        "目标不会等我分心回来",
        "现在放弃刚才的坚持就白费了"
    ]

    /// 生成确认短语。focusedMinutes 为 nil 表示无会话(关闭手动锁定)。
    static func phrase(now: Date, focusedMinutes: Int?, lineIndex: Int) -> String {
        let count = closingLines.count
        let line = closingLines[((lineIndex % count) + count) % count]
        let time = timeFormatter.string(from: now)
        if let focusedMinutes {
            return "现在是 \(time),我放弃已进行 \(focusedMinutes) 分钟的专注,\(line)"
        }
        return "现在是 \(time),我确定要解除手动锁定,\(line)"
    }

    static func randomPhrase(now: Date, focusedMinutes: Int?) -> String {
        phrase(
            now: now,
            focusedMinutes: focusedMinutes,
            lineIndex: Int.random(in: 0..<closingLines.count)
        )
    }

    static func matches(_ input: String, phrase: String) -> Bool {
        input.trimmingCharacters(in: .whitespacesAndNewlines) == phrase
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
