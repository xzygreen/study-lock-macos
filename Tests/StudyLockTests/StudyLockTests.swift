import Foundation
import Testing
@testable import StudyLock

// MARK: - LockPolicy

@Test func whitelistedApplicationIsAllowed() {
    let allowed = LockPolicy.allows(
        bundleIdentifier: "com.example.reader",
        bundleURL: URL(fileURLWithPath: "/Applications/Reader.app"),
        processIdentifier: 120,
        ownProcessIdentifier: 999,
        whitelist: ["com.example.reader"]
    )
    #expect(allowed)
}

@Test func unknownApplicationIsBlocked() {
    let allowed = LockPolicy.allows(
        bundleIdentifier: "com.example.social",
        bundleURL: URL(fileURLWithPath: "/Applications/Social.app"),
        processIdentifier: 120,
        ownProcessIdentifier: 999,
        whitelist: []
    )
    #expect(!allowed)
}

@Test func ownProcessAndFinderAreAlwaysAllowed() {
    #expect(
        LockPolicy.allows(
            bundleIdentifier: "cn.studylock.app",
            bundleURL: nil,
            processIdentifier: 999,
            ownProcessIdentifier: 999,
            whitelist: []
        )
    )
    #expect(
        LockPolicy.allows(
            bundleIdentifier: "com.apple.finder",
            bundleURL: nil,
            processIdentifier: 120,
            ownProcessIdentifier: 999,
            whitelist: []
        )
    )
}

@Test func forcedBlacklistOverridesWhitelist() {
    // 系统设置即使被加入白名单,锁定期间也强制隐藏
    for bundleID in ["com.apple.systempreferences", "com.apple.ActivityMonitor"] {
        #expect(
            !LockPolicy.allows(
                bundleIdentifier: bundleID,
                bundleURL: nil,
                processIdentifier: 120,
                ownProcessIdentifier: 999,
                whitelist: [bundleID]
            )
        )
    }
}

@Test func pathIdentitySupportsAppsWithoutBundleIdentifier() {
    let url = URL(fileURLWithPath: "/Applications/Local Tool.app")
    #expect(
        AppIdentity.key(bundleIdentifier: nil, bundleURL: url)
            == "path:/Applications/Local Tool.app"
    )
}

// MARK: - DurationFormatter

@Test func countdownFormattingRoundsUp() {
    #expect(DurationFormatter.countdown(65.1) == "01:06")
    #expect(DurationFormatter.countdown(0) == "00:00")
    #expect(DurationFormatter.countdown(-10) == "00:00")
}

@Test func countdownFormattingHandlesHours() {
    #expect(DurationFormatter.countdown(3600) == "1:00:00")
    #expect(DurationFormatter.countdown(5400) == "1:30:00")
}

@Test func elapsedFormattingRoundsDown() {
    #expect(DurationFormatter.elapsed(65.9) == "01:05")
    #expect(DurationFormatter.elapsed(0) == "00:00")
    #expect(DurationFormatter.elapsed(3725) == "1:02:05")
}

// MARK: - PomodoroSchedule

private let schedule = PomodoroSchedule(focusMinutes: 25, breakMinutes: 5, rounds: 4)

@Test func pomodoroTotalDurationExcludesTrailingBreak() {
    // 4×25 专注 + 3×5 休息 = 115 分钟
    #expect(schedule.totalSeconds == 115 * 60)
    #expect(schedule.totalFocusSeconds == 100 * 60)
}

@Test func pomodoroPhaseProgression() {
    // t=0 → 第 1 轮专注开始
    #expect(schedule.phase(elapsed: 0) == .focus(round: 1, remaining: 25 * 60))
    // t=10min → 第 1 轮专注中
    #expect(schedule.phase(elapsed: 10 * 60) == .focus(round: 1, remaining: 15 * 60))
    // t=25min → 第 1 轮休息开始
    #expect(schedule.phase(elapsed: 25 * 60) == .rest(round: 1, remaining: 5 * 60))
    // t=29min → 第 1 轮休息还剩 1 分钟
    #expect(schedule.phase(elapsed: 29 * 60) == .rest(round: 1, remaining: 60))
    // t=30min → 第 2 轮专注开始
    #expect(schedule.phase(elapsed: 30 * 60) == .focus(round: 2, remaining: 25 * 60))
    // t=90min → 第 4 轮(最后一轮)专注开始
    #expect(schedule.phase(elapsed: 90 * 60) == .focus(round: 4, remaining: 25 * 60))
    // t=115min → 完成(最后一轮无尾休息)
    #expect(schedule.phase(elapsed: 115 * 60) == .finished)
    #expect(schedule.phase(elapsed: 200 * 60) == .finished)
}

@Test func pomodoroFocusedSecondsExcludesBreaks() {
    #expect(schedule.focusedSeconds(elapsed: 0) == 0)
    // 专注 10 分钟
    #expect(schedule.focusedSeconds(elapsed: 10 * 60) == 10 * 60)
    // 25 分钟专注 + 3 分钟休息 → 只算 25 分钟
    #expect(schedule.focusedSeconds(elapsed: 28 * 60) == 25 * 60)
    // 一轮整(25+5)+ 第 2 轮 5 分钟 → 30 分钟
    #expect(schedule.focusedSeconds(elapsed: 35 * 60) == 30 * 60)
    // 全部结束 → 100 分钟纯专注
    #expect(schedule.focusedSeconds(elapsed: 115 * 60) == 100 * 60)
    #expect(schedule.focusedSeconds(elapsed: 999 * 60) == 100 * 60)
}

@Test func singleRoundPomodoroFinishesAfterFocus() {
    let single = PomodoroSchedule(focusMinutes: 25, breakMinutes: 5, rounds: 1)
    #expect(single.totalSeconds == 25 * 60)
    #expect(single.phase(elapsed: 10 * 60) == .focus(round: 1, remaining: 15 * 60))
    #expect(single.phase(elapsed: 25 * 60) == .finished)
}

// MARK: - 记录迁移

@Test func legacyRecordMigratesToCountdownMode() throws {
    let legacy = LegacyFocusRecord(
        id: UUID(),
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        endedAt: Date(timeIntervalSince1970: 1_700_000_000 + 45 * 60),
        plannedMinutes: 45,
        completed: true
    )
    let migrated = legacy.migrated
    #expect(migrated.id == legacy.id)
    #expect(migrated.mode == .countdown)
    #expect(migrated.plannedMinutes == 45)
    #expect(migrated.completed)
    #expect(migrated.focusSeconds == nil)
    #expect(migrated.focusedMinutes == 45)

    // v1 JSON(无 mode 字段)能解码为 LegacyFocusRecord
    let v1JSON = """
    [{"id":"\(legacy.id.uuidString)","startedAt":700000000,"endedAt":700002700,\
    "plannedMinutes":45,"completed":true}]
    """
    let decoded = try JSONDecoder().decode(
        [LegacyFocusRecord].self,
        from: Data(v1JSON.utf8)
    )
    #expect(decoded.count == 1)
    #expect(decoded[0].plannedMinutes == 45)
}

// MARK: - FocusRecord

@Test func focusRecordPrefersExplicitFocusSeconds() {
    let start = Date(timeIntervalSince1970: 0)
    let record = FocusRecord(
        id: UUID(),
        startedAt: start,
        endedAt: start.addingTimeInterval(115 * 60),
        mode: .pomodoro,
        plannedMinutes: 100,
        completed: true,
        focusSeconds: 100 * 60
    )
    // 起止跨 115 分钟,但纯专注 100 分钟
    #expect(record.focusedMinutes == 100)
}

@Test func subMinuteFocusDoesNotRoundUpToOneMinute() {
    let start = Date(timeIntervalSince1970: 0)
    let record = FocusRecord(
        id: UUID(), startedAt: start, endedAt: start.addingTimeInterval(30),
        mode: .countdown, plannedMinutes: 25, completed: false, focusSeconds: 30
    )
    #expect(record.focusedMinutes == 0)
}

// MARK: - 确认短语

@Test func exitConfirmationPhraseIsDeterministicAndTimeAware() {
    let noon = Date(timeIntervalSince1970: 1_700_000_000) // UTC 09:13,本地随时区
    let phrase = ExitConfirmation.phrase(now: noon, focusedMinutes: 12, lineIndex: 0)
    #expect(phrase.contains("我放弃已进行 12 分钟的专注"))
    #expect(phrase.hasSuffix(ExitConfirmation.closingLines[0]))
    // 同参数生成结果一致
    #expect(phrase == ExitConfirmation.phrase(now: noon, focusedMinutes: 12, lineIndex: 0))
    // 尾句索引取模,越界不崩溃
    let count = ExitConfirmation.closingLines.count
    #expect(
        ExitConfirmation.phrase(now: noon, focusedMinutes: 12, lineIndex: count + 1)
            == ExitConfirmation.phrase(now: noon, focusedMinutes: 12, lineIndex: 1)
    )
}

@Test func exitConfirmationManualLockVariantOmitsMinutes() {
    let phrase = ExitConfirmation.phrase(
        now: Date(timeIntervalSince1970: 0),
        focusedMinutes: nil,
        lineIndex: 2
    )
    #expect(phrase.contains("解除手动锁定"))
    #expect(!phrase.contains("分钟的专注"))
}

@Test func exitConfirmationRequiresExactPhrase() {
    let phrase = ExitConfirmation.phrase(
        now: Date(timeIntervalSince1970: 1_700_000_000),
        focusedMinutes: 5,
        lineIndex: 1
    )
    #expect(ExitConfirmation.matches(phrase, phrase: phrase))
    #expect(ExitConfirmation.matches("  \(phrase) \n", phrase: phrase))
    #expect(!ExitConfirmation.matches(phrase + "!", phrase: phrase))
    #expect(!ExitConfirmation.matches(String(phrase.dropLast()), phrase: phrase))
    #expect(!ExitConfirmation.matches("", phrase: phrase))
}

// MARK: - 退出摩擦力 / 污点

@Test func cooldownGrowsWithTaints() {
    #expect(ExitFriction.cooldownSeconds(recentTaintCount: 0) == 10)
    #expect(ExitFriction.cooldownSeconds(recentTaintCount: 1) == 20)
    #expect(ExitFriction.cooldownSeconds(recentTaintCount: 2) == 30)
    #expect(ExitFriction.cooldownSeconds(recentTaintCount: 3) == 60)
    #expect(ExitFriction.cooldownSeconds(recentTaintCount: 9) == 60)
}

@Test func taintLedgerKeepsOnlyRecentSevenDays() {
    let now = Date(timeIntervalSince1970: 1_700_000_000)
    let taints = [
        now.addingTimeInterval(-8 * 24 * 3600), // 过期
        now.addingTimeInterval(-6 * 24 * 3600),
        now.addingTimeInterval(-3600)
    ]
    #expect(TaintLedger.recentCount(taints, now: now) == 2)
    #expect(TaintLedger.pruned(taints, now: now).count == 2)
}

// MARK: - 恢复决策

private func makeSession(
    mode: FocusMode,
    startedAt: Date,
    countdownMinutes: Int = 45,
    schedule: PomodoroSchedule? = nil
) -> ActiveSession {
    ActiveSession(
        mode: mode,
        startedAt: startedAt,
        countdownMinutes: countdownMinutes,
        schedule: schedule,
        title: ""
    )
}

@Test func recoveryResumesCountdownStillInWindow() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let session = makeSession(mode: .countdown, startedAt: start, countdownMinutes: 45)
    // 5 分钟后重启,心跳新鲜 → 恢复
    let decision = RecoveryDecision.decide(
        session: session,
        lastHeartbeat: start.addingTimeInterval(4 * 60),
        now: start.addingTimeInterval(5 * 60)
    )
    #expect(decision == .resume(session))
}

@Test func recoveryFinalizesCountdownPastWindow() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let session = makeSession(mode: .countdown, startedAt: start, countdownMinutes: 45)
    // 46 分钟后重启(计划窗口已过),心跳在 44 分钟 → 按心跳结算
    let heartbeat = start.addingTimeInterval(44 * 60)
    let decision = RecoveryDecision.decide(
        session: session,
        lastHeartbeat: heartbeat,
        now: start.addingTimeInterval(46 * 60)
    )
    #expect(decision == .finalize(endedAt: heartbeat, focusSeconds: 44 * 60))
}

@Test func recoveryFinalizesWhenHeartbeatIsStale() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let session = makeSession(mode: .countdown, startedAt: start, countdownMinutes: 45)
    // 心跳停在 10 分钟处,3 小时后才重启 → 早已退出,按心跳结算
    let heartbeat = start.addingTimeInterval(10 * 60)
    let decision = RecoveryDecision.decide(
        session: session,
        lastHeartbeat: heartbeat,
        now: start.addingTimeInterval(3 * 3600)
    )
    #expect(decision == .finalize(endedAt: heartbeat, focusSeconds: 10 * 60))
}

@Test func recoveryAlwaysResumesFreshCountUp() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let session = makeSession(mode: .countUp, startedAt: start)
    let decision = RecoveryDecision.decide(
        session: session,
        lastHeartbeat: start.addingTimeInterval(50 * 60),
        now: start.addingTimeInterval(51 * 60)
    )
    #expect(decision == .resume(session))
}

@Test func recoveryPomodoroUsesScheduleWindowAndExcludesBreaks() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let schedule = PomodoroSchedule(focusMinutes: 25, breakMinutes: 5, rounds: 4)
    let session = makeSession(mode: .pomodoro, startedAt: start, schedule: schedule)
    // 60 分钟处(第 3 轮专注中)心跳新鲜 → 恢复
    #expect(
        RecoveryDecision.decide(
            session: session,
            lastHeartbeat: start.addingTimeInterval(59 * 60),
            now: start.addingTimeInterval(60 * 60)
        ) == .resume(session)
    )
    // 心跳停在 28 分钟(第 1 轮休息中),4 小时后重启 → 结算纯专注 25 分钟
    #expect(
        RecoveryDecision.decide(
            session: session,
            lastHeartbeat: start.addingTimeInterval(28 * 60),
            now: start.addingTimeInterval(4 * 3600)
        ) == .finalize(endedAt: start.addingTimeInterval(28 * 60), focusSeconds: 25 * 60)
    )
}

@Test func recoveryWithoutHeartbeatFallsBackToStart() {
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let session = makeSession(mode: .countdown, startedAt: start, countdownMinutes: 45)
    // 无心跳、20 分钟后重启 → 心跳视为 startedAt,已超宽限 → 按开始时间结算(0 专注)
    let decision = RecoveryDecision.decide(
        session: session,
        lastHeartbeat: nil,
        now: start.addingTimeInterval(20 * 60)
    )
    #expect(decision == .finalize(endedAt: start, focusSeconds: 0))
}

// MARK: - 质量分

@Test func focusQualityScoring() {
    #expect(FocusQuality.score(interruptions: 0, endReason: .completed) == 100)
    #expect(FocusQuality.score(interruptions: 3, endReason: .completed) == 76)
    #expect(FocusQuality.score(interruptions: 0, endReason: .early) == 75)
    #expect(FocusQuality.score(interruptions: 0, endReason: .forceQuit) == 50)
    #expect(FocusQuality.score(interruptions: 20, endReason: .forceQuit) == 0)
}

@Test func focusRecordQualityScoreIsNilForLegacyRecords() {
    let start = Date(timeIntervalSince1970: 0)
    let legacy = FocusRecord(
        id: UUID(),
        startedAt: start,
        endedAt: start.addingTimeInterval(600),
        mode: .countdown,
        plannedMinutes: 10,
        completed: true,
        focusSeconds: 600
    )
    #expect(legacy.qualityScore == nil)

    let modern = FocusRecord(
        id: UUID(),
        startedAt: start,
        endedAt: start.addingTimeInterval(600),
        mode: .countdown,
        plannedMinutes: 10,
        completed: true,
        focusSeconds: 600,
        interruptionCount: 2,
        endReason: .completed
    )
    #expect(modern.qualityScore == 84)
}

@Test func focusRecordV2JSONWithoutNewFieldsStillDecodes() throws {
    // v2.0 存量记录没有 interruptionCount / endReason
    let id = UUID()
    let json = """
    [{"id":"\(id.uuidString)","startedAt":700000000,"endedAt":700002700,\
    "mode":"countdown","plannedMinutes":45,"completed":true}]
    """
    let decoded = try JSONDecoder().decode([FocusRecord].self, from: Data(json.utf8))
    #expect(decoded.count == 1)
    #expect(decoded[0].interruptionCount == nil)
    #expect(decoded[0].endReason == nil)
    #expect(decoded[0].qualityScore == nil)
}

// MARK: - 连续打卡

private func record(daysAgo: Int, from today: Date, completed: Bool = true) -> FocusRecord {
    let started = Calendar.current.date(byAdding: .day, value: -daysAgo, to: today)!
    return FocusRecord(
        id: UUID(),
        startedAt: started,
        endedAt: started.addingTimeInterval(1500),
        mode: .countdown,
        plannedMinutes: 25,
        completed: completed,
        focusSeconds: 1500
    )
}

@Test func streakCountsConsecutiveDaysEndingTodayOrYesterday() {
    let today = Date(timeIntervalSince1970: 1_700_000_000)
    // 今天 + 昨天 + 前天 → 3
    #expect(
        StreakCalculator.streak(
            records: [record(daysAgo: 0, from: today), record(daysAgo: 1, from: today),
                      record(daysAgo: 2, from: today)],
            today: today
        ) == 3
    )
    // 今天没打卡,但昨天/前天有 → 2(宽限,尚未断签)
    #expect(
        StreakCalculator.streak(
            records: [record(daysAgo: 1, from: today), record(daysAgo: 2, from: today)],
            today: today
        ) == 2
    )
    // 中间断一天 → 只算端点侧
    #expect(
        StreakCalculator.streak(
            records: [record(daysAgo: 0, from: today), record(daysAgo: 2, from: today)],
            today: today
        ) == 1
    )
    // 最近完成在前天 → 已断签
    #expect(
        StreakCalculator.streak(records: [record(daysAgo: 2, from: today)], today: today) == 0
    )
    // 未完成的记录不算打卡
    #expect(
        StreakCalculator.streak(
            records: [record(daysAgo: 0, from: today, completed: false)],
            today: today
        ) == 0
    )
    #expect(StreakCalculator.streak(records: [], today: today) == 0)
}

// MARK: - 按日聚合

@Test func dailyTotalsFillsMissingDaysAndAveragesQuality() {
    let today = Date(timeIntervalSince1970: 1_700_000_000)
    let calendar = Calendar.current
    let start = calendar.startOfDay(for: today)
    let records = [
        FocusRecord(
            id: UUID(), startedAt: start.addingTimeInterval(3600),
            endedAt: start.addingTimeInterval(3600 + 1500), mode: .countdown,
            plannedMinutes: 25, completed: true, focusSeconds: 1500,
            interruptionCount: 0, endReason: .completed
        ),
        FocusRecord(
            id: UUID(), startedAt: start.addingTimeInterval(7200),
            endedAt: start.addingTimeInterval(7200 + 600), mode: .countdown,
            plannedMinutes: 25, completed: false, focusSeconds: 600,
            interruptionCount: 0, endReason: .early
        )
    ]
    let totals = FocusAggregator.dailyTotals(records: records, days: 7, today: today)
    #expect(totals.count == 7)
    #expect(totals.last?.day == start)
    // 未完成会话不计分钟,但质量分参与平均:(100 + 75) / 2 = 87
    #expect(totals.last?.focusedMinutes == 25)
    #expect(totals.last?.averageQuality == 87)
    // 其余六天补零
    #expect(totals.dropLast().allSatisfy { $0.focusedMinutes == 0 && $0.averageQuality == nil })
}

// MARK: - 域名规范化

@Test func domainNormalizationStripsURLNoise() {
    #expect(DomainRule.normalize("bilibili.com") == "bilibili.com")
    #expect(DomainRule.normalize("  HTTPS://WWW.Bilibili.com/video/BV1?x=1  ") == "bilibili.com")
    #expect(DomainRule.normalize("http://weibo.com:8080/hot") == "weibo.com")
    #expect(DomainRule.normalize("www.youtube.com") == "youtube.com")
    #expect(DomainRule.normalize("sub.domain.example.co.uk") == "sub.domain.example.co.uk")
}

@Test func domainNormalizationRejectsInvalidInput() {
    #expect(DomainRule.normalize("") == nil)
    #expect(DomainRule.normalize("   ") == nil)
    #expect(DomainRule.normalize("localhost") == nil) // 无点
    #expect(DomainRule.normalize(".com") == nil)
    #expect(DomainRule.normalize("bad domain.com") == nil)
    #expect(DomainRule.normalize("emoji😀.com") == nil)
}

@Test func domainRuleOnlyIgnoresBlankAboutPage() {
    #expect(DomainRule.isIgnorablePage("about:blank"))
    #expect(DomainRule.isIgnorablePage(""))
    #expect(!DomainRule.isIgnorablePage("file:///tmp/page.html"))
    #expect(!DomainRule.isIgnorablePage("chrome://extensions"))
    #expect(!DomainRule.isIgnorablePage("http://localhost:8080"))
}

@Test func domainWhitelistMatchesExactAndSubdomains() {
    let whitelist: Set<String> = ["wikipedia.org", "github.com"]
    #expect(DomainRule.isAllowed("wikipedia.org", whitelist: whitelist))
    #expect(DomainRule.isAllowed("zh.wikipedia.org", whitelist: whitelist))
    #expect(DomainRule.isAllowed("gist.github.com", whitelist: whitelist))
    // 伪后缀不放行
    #expect(!DomainRule.isAllowed("notgithub.com", whitelist: whitelist))
    #expect(!DomainRule.isAllowed("github.com.evil.net", whitelist: whitelist))
    #expect(!DomainRule.isAllowed("bilibili.com", whitelist: whitelist))
    // 空白名单一律不允许
    #expect(!DomainRule.isAllowed("wikipedia.org", whitelist: []))
}

// MARK: - 代理快照

@Test func proxySnapshotRoundTripAndUpstream() throws {
    let wifi = ProxyServiceSnapshot(
        serviceName: "Wi-Fi",
        webProxyEnabled: true, webProxyHost: "127.0.0.1", webProxyPort: 7890,
        secureWebProxyEnabled: true, secureWebProxyHost: "127.0.0.1", secureWebProxyPort: 7890,
        autoProxyURL: "", autoProxyEnabled: false
    )
    let ethernet = ProxyServiceSnapshot(
        serviceName: "Thunderbolt Bridge",
        webProxyEnabled: false, webProxyHost: "", webProxyPort: 0,
        secureWebProxyEnabled: false, secureWebProxyHost: "", secureWebProxyPort: 0,
        autoProxyURL: "", autoProxyEnabled: false
    )
    let snapshot = ProxySnapshot(services: [ethernet, wifi])
    #expect(snapshot.upstream! == ("127.0.0.1", 7890))
    #expect(ProxySnapshot(services: [ethernet]).upstream == nil)

    let data = try JSONEncoder().encode(snapshot)
    let decoded = try JSONDecoder().decode(ProxySnapshot.self, from: data)
    #expect(decoded == snapshot)
}

@Test func focusRecordBlockedNetworkDomainsBackwardCompatible() throws {
    let json = """
    [{"id":"\(UUID().uuidString)","startedAt":700000000,"endedAt":700002700,\
    "mode":"countdown","plannedMinutes":45,"completed":true}]
    """
    let decoded = try JSONDecoder().decode([FocusRecord].self, from: Data(json.utf8))
    #expect(decoded[0].blockedNetworkDomains == nil)
}

@Test func focusReportIncludesBlockedNetworkDomains() {
    let today = Date(timeIntervalSince1970: 1_700_000_000)
    let start = Calendar.current.startOfDay(for: today)
    let record = FocusRecord(
        id: UUID(), startedAt: start.addingTimeInterval(3600),
        endedAt: start.addingTimeInterval(3600 + 1500), mode: .countdown,
        plannedMinutes: 25, completed: true, focusSeconds: 1500,
        interruptionCount: 0, endReason: .completed,
        blockedNetworkDomains: ["bilibili.com", "weibo.com"]
    )
    let report = FocusReport.markdown(records: [record], days: 7, today: today)
    #expect(report.contains("被拦网站:bilibili.com、weibo.com"))
}

// MARK: - 浏览器识别

@Test func browserPolicyRecognizesKnownBrowsers() {
    #expect(BrowserPolicy.dialect(for: "com.apple.Safari") == .safari)
    #expect(BrowserPolicy.dialect(for: "com.google.Chrome") == .chromium)
    // Beta/Dev/Canary 渠道与稳定版脚本接口一致,同样受控
    #expect(BrowserPolicy.dialect(for: "com.google.Chrome.beta") == .chromium)
    #expect(BrowserPolicy.dialect(for: "com.google.Chrome.canary") == .chromium)
    #expect(BrowserPolicy.dialect(for: "com.microsoft.edgemac.Canary") == .chromium)
    #expect(BrowserPolicy.dialect(for: "org.chromium.Chromium") == .chromium)
    #expect(BrowserPolicy.isBrowser("com.microsoft.edgemac"))
    #expect(!BrowserPolicy.isBrowser("com.apple.TextEdit"))
    #expect(!BrowserPolicy.isBrowser(nil))
}

// MARK: - 使用时长

@Test func usageTallyAccumulatesSortsAndMerges() throws {
    var tally = UsageTally()
    #expect(tally.isEmpty)
    tally.addApp("Xcode", seconds: 10)
    tally.addApp("Xcode", seconds: 5)
    tally.addApp("Safari", seconds: 30)
    tally.addSite("wikipedia.org", seconds: 20)
    #expect(tally.apps["Xcode"] == 15)
    #expect(tally.topApps.map(\.name) == ["Safari", "Xcode"])
    #expect(tally.topSites.first?.seconds == 20)

    var other = UsageTally()
    other.addApp("Xcode", seconds: 100)
    other.addSite("github.com", seconds: 7)
    let merged = tally.merging(other)
    #expect(merged.apps["Xcode"] == 115)
    #expect(merged.sites.count == 2)

    // Codable 往返
    let data = try JSONEncoder().encode(tally)
    let decoded = try JSONDecoder().decode(UsageTally.self, from: data)
    #expect(decoded == tally)
}

@Test func focusRecordV21JSONWithoutUsageStillDecodes() throws {
    let json = """
    [{"id":"\(UUID().uuidString)","startedAt":700000000,"endedAt":700002700,\
    "mode":"countdown","plannedMinutes":45,"completed":true,\
    "interruptionCount":1,"endReason":"completed"}]
    """
    let decoded = try JSONDecoder().decode([FocusRecord].self, from: Data(json.utf8))
    #expect(decoded[0].usage == nil)
    #expect(decoded[0].qualityScore == 92)
}

// MARK: - 报告

@Test func focusReportMarkdownContainsSummaryUsageAndSessions() {
    let today = Date(timeIntervalSince1970: 1_700_000_000)
    let start = Calendar.current.startOfDay(for: today)
    var usage = UsageTally()
    usage.addApp("预览", seconds: 900)
    usage.addApp("Safari", seconds: 600)
    usage.addSite("wikipedia.org", seconds: 480)
    let records = [
        FocusRecord(
            id: UUID(), startedAt: start.addingTimeInterval(3600),
            endedAt: start.addingTimeInterval(3600 + 1500), mode: .countdown,
            plannedMinutes: 25, completed: true, focusSeconds: 1500,
            interruptionCount: 2, endReason: .completed, usage: usage
        ),
        FocusRecord(
            id: UUID(), startedAt: start.addingTimeInterval(-20 * 24 * 3600),
            endedAt: start.addingTimeInterval(-20 * 24 * 3600 + 600), mode: .countUp,
            plannedMinutes: 0, completed: true, focusSeconds: 600
        )
    ]
    let report = FocusReport.markdown(records: records, days: 7, today: today)
    #expect(report.contains("# 认真 · 专注报告(近 7 天)"))
    #expect(report.contains("| 完成专注 | 1 次 / 25 分钟 |"))
    #expect(report.contains("| 平均质量分 | 84 |"))
    #expect(report.contains("| 分心拦截 | 2 次 |"))
    #expect(report.contains("| 预览 | 15 分钟 |"))
    #expect(report.contains("| wikipedia.org | 8 分钟 |"))
    #expect(report.contains("## 会话明细"))
    #expect(report.contains("质量 84,拦截 2 次"))
    // 区间外记录(20 天前)不入明细,但逐日表覆盖 7 行
    #expect(!report.contains("正计时"))
    #expect(report.components(separatedBy: "\n").filter { $0.hasPrefix("| 2") }.count == 7)
}

@Test func focusReportDurationFormatting() {
    #expect(FocusReport.durationText(45) == "45 秒")
    #expect(FocusReport.durationText(150) == "2 分钟")
    #expect(FocusReport.durationText(3900) == "1 小时 5 分钟")
}

// MARK: - hosts 文件变换

private let sampleHosts = """
##
# Host Database
##
127.0.0.1\tlocalhost
255.255.255.255\tbroadcasthost
::1                          localhost
"""

@Test func hostsInsertionAppendsMarkedBlock() {
    let result = HostsFileEditor.inserting(domains: ["bilibili.com"], into: sampleHosts)
    #expect(result.contains(HostsFileEditor.beginMarker))
    #expect(result.contains(HostsFileEditor.endMarker))
    #expect(result.contains("127.0.0.1\tbilibili.com"))
    #expect(result.contains("127.0.0.1\twww.bilibili.com"))
    #expect(result.contains("::1\tbilibili.com"))
    #expect(result.contains("::1\twww.bilibili.com"))
    // 原内容原样保留
    #expect(result.hasPrefix("##\n# Host Database\n##\n127.0.0.1\tlocalhost"))
    #expect(HostsFileEditor.containsBlock(result))
    #expect(!HostsFileEditor.containsBlock(sampleHosts))
}

@Test func hostsInsertionIsIdempotent() {
    let once = HostsFileEditor.inserting(domains: ["bilibili.com"], into: sampleHosts)
    // 换域名重插:旧块被剥离,不叠加
    let twice = HostsFileEditor.inserting(domains: ["weibo.com"], into: once)
    #expect(!twice.contains("bilibili.com"))
    #expect(twice.contains("127.0.0.1\tweibo.com"))
    #expect(twice.components(separatedBy: HostsFileEditor.beginMarker).count == 2)
    // 同域名重插结果稳定
    #expect(
        HostsFileEditor.inserting(domains: ["weibo.com"], into: twice) == twice
    )
}

@Test func hostsRemovalRestoresOriginal() {
    let inserted = HostsFileEditor.inserting(
        domains: ["bilibili.com", "weibo.com"],
        into: sampleHosts
    )
    let removed = HostsFileEditor.removingBlock(from: inserted)
    #expect(removed == sampleHosts + "\n")
    #expect(!removed.contains("bilibili.com"))
    // 对无块内容是无操作(仅规范尾部换行)
    #expect(HostsFileEditor.removingBlock(from: removed) == removed)
}

@Test func unmatchedHostsBeginMarkerPreservesFollowingLines() {
    let contents = "127.0.0.1 localhost\n\(HostsFileEditor.beginMarker)\n1.2.3.4 important.example\n"
    let removed = HostsFileEditor.removingBlock(from: contents)
    #expect(!removed.contains(HostsFileEditor.beginMarker))
    #expect(removed.contains("1.2.3.4 important.example"))
}

@Test func hostsInsertionWithEmptyDomainsEqualsRemoval() {
    let inserted = HostsFileEditor.inserting(domains: ["bilibili.com"], into: sampleHosts)
    #expect(
        HostsFileEditor.inserting(domains: [], into: inserted)
            == HostsFileEditor.removingBlock(from: inserted)
    )
}

// MARK: - 会话快照

@Test func activeSessionRoundTripsThroughJSON() throws {
    let session = ActiveSession(
        mode: .pomodoro,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        countdownMinutes: 45,
        schedule: PomodoroSchedule(focusMinutes: 25, breakMinutes: 5, rounds: 4),
        title: "读论文"
    )
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(ActiveSession.self, from: data)
    #expect(decoded == session)
}

// MARK: - 定时课程表

/// 2026-07-06 是周一,2026-07-11 是周六。
private func date(
    _ year: Int, _ month: Int, _ day: Int,
    _ hour: Int = 0, _ minute: Int = 0
) -> Date {
    Calendar.current.date(
        from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)
    )!
}

private func enabledTimetable(
    slots: [TimeSlot] = FocusTimetable.defaultSlots,
    weekdays: Set<Int> = FocusTimetable.defaultWeekdays,
    skip: [Date] = [],
    force: [Date] = []
) -> FocusTimetable {
    FocusTimetable(
        isEnabled: true,
        slots: slots,
        activeWeekdays: weekdays,
        skipDates: skip,
        forceDates: force
    )
}

@Test func midnightTimeTextUsesTwentyFourHours() {
    #expect(TimeSlot.timeText(24 * 60) == "24:00")
}

@Test func currentSlotMatchesInsideAndMissesGap() {
    let timetable = enabledTimetable()
    // 周一 9:20 → 第一时段
    let hit = TimetableScheduler.currentSlot(at: date(2026, 7, 6, 9, 20), timetable: timetable)
    #expect(hit?.startMinute == 9 * 60)
    // 10:50 是 10:45-10:55 的间隙
    #expect(TimetableScheduler.currentSlot(at: date(2026, 7, 6, 10, 50), timetable: timetable) == nil)
    // 18:10 全部结束
    #expect(TimetableScheduler.currentSlot(at: date(2026, 7, 6, 18, 10), timetable: timetable) == nil)
    // 未启用 → nil
    var disabled = timetable
    disabled.isEnabled = false
    #expect(TimetableScheduler.currentSlot(at: date(2026, 7, 6, 9, 20), timetable: disabled) == nil)
}

@Test func currentSlotBoundaryIsHalfOpen() {
    let timetable = enabledTimetable()
    // 9:45 恰好是第一时段的结束、第二时段的开始 → 属于第二时段
    let slot = TimetableScheduler.currentSlot(at: date(2026, 7, 6, 9, 45), timetable: timetable)
    #expect(slot?.startMinute == 9 * 60 + 45)
    #expect(slot?.endMinute == 10 * 60 + 45)
}

@Test func isActiveDayRespectsWeekdaySkipAndForce() {
    let monday = date(2026, 7, 6)
    let saturday = date(2026, 7, 11)

    let plain = enabledTimetable()
    #expect(TimetableScheduler.isActiveDay(monday, timetable: plain))
    #expect(!TimetableScheduler.isActiveDay(saturday, timetable: plain))

    // skip 让工作日失效
    let skipped = enabledTimetable(skip: [monday])
    #expect(!TimetableScheduler.isActiveDay(date(2026, 7, 6, 9, 20), timetable: skipped))

    // force 让周六生效
    let forced = enabledTimetable(force: [saturday])
    #expect(TimetableScheduler.isActiveDay(date(2026, 7, 11, 9, 20), timetable: forced))

    // force 优先于 skip
    let both = enabledTimetable(skip: [monday], force: [monday])
    #expect(TimetableScheduler.isActiveDay(monday, timetable: both))
}

@Test func nextSlotFindsUpcomingAndReturnsNilAfterLast() {
    let timetable = enabledTimetable()
    // 10:50(间隙)→ 下一时段 10:55
    let next = TimetableScheduler.nextSlot(after: date(2026, 7, 6, 10, 50), timetable: timetable)
    #expect(next?.startMinute == 10 * 60 + 55)
    // 9:20(时段内)→ 下一时段是 9:45 那段
    let during = TimetableScheduler.nextSlot(after: date(2026, 7, 6, 9, 20), timetable: timetable)
    #expect(during?.startMinute == 9 * 60 + 45)
    // 18:10 → nil
    #expect(TimetableScheduler.nextSlot(after: date(2026, 7, 6, 18, 10), timetable: timetable) == nil)
    // 周六 → nil
    #expect(TimetableScheduler.nextSlot(after: date(2026, 7, 11, 8, 0), timetable: timetable) == nil)
}

@Test func validateRejectsOverlapAndInvertedSlots() {
    #expect(TimetableScheduler.validate(slots: FocusTimetable.defaultSlots))
    // 相邻(9:45 结束 = 9:45 开始)合法
    #expect(TimetableScheduler.validate(slots: [
        TimeSlot(startHour: 9, startMin: 0, endHour: 9, endMin: 45),
        TimeSlot(startHour: 9, startMin: 45, endHour: 10, endMin: 45)
    ]))
    // 重叠
    #expect(!TimetableScheduler.validate(slots: [
        TimeSlot(startHour: 9, startMin: 0, endHour: 10, endMin: 0),
        TimeSlot(startHour: 9, startMin: 30, endHour: 10, endMin: 30)
    ]))
    // 开始不早于结束
    #expect(!TimetableScheduler.validate(slots: [
        TimeSlot(startHour: 10, startMin: 0, endHour: 9, endMin: 0)
    ]))
}

@Test func remainingSecondsCountsToSlotEnd() {
    let slot = TimeSlot(startHour: 9, startMin: 0, endHour: 9, endMin: 45)
    #expect(
        TimetableScheduler.remainingSeconds(in: slot, at: date(2026, 7, 6, 9, 20)) == 25 * 60
    )
}

@Test func dismissKeyIsPerSlotPerDay() {
    let slot = FocusTimetable.defaultSlots[0]
    let monday = TimetableScheduler.dismissKey(slotID: slot.id, on: date(2026, 7, 6, 9, 30))
    let tuesday = TimetableScheduler.dismissKey(slotID: slot.id, on: date(2026, 7, 7, 9, 30))
    #expect(monday != tuesday)
    #expect(monday.contains("2026-07-06"))
    #expect(TimetableScheduler.keyIsForDay(monday, date: date(2026, 7, 6, 23, 59)))
    #expect(!TimetableScheduler.keyIsForDay(monday, date: date(2026, 7, 7)))
}

@Test func timetableRoundTripsThroughJSONAndHasSaneDefaults() throws {
    let timetable = enabledTimetable(
        skip: [date(2026, 10, 1)],
        force: [date(2026, 9, 27)]
    )
    let data = try JSONEncoder().encode(timetable)
    let decoded = try JSONDecoder().decode(FocusTimetable.self, from: data)
    #expect(decoded == timetable)

    let defaults = FocusTimetable.default
    #expect(!defaults.isEnabled)
    #expect(defaults.slots.count == 7)
    #expect(defaults.activeWeekdays == [2, 3, 4, 5, 6])
    #expect(TimetableScheduler.validate(slots: defaults.slots))
}

@Test func activeSessionDecodesWithoutScheduledSlotID() throws {
    // 旧版快照 JSON 无 scheduledSlotID 字段
    let legacyJSON = """
    {"mode":"countdown","startedAt":700000000,"countdownMinutes":45,"title":"旧会话"}
    """
    let decoded = try JSONDecoder().decode(ActiveSession.self, from: Data(legacyJSON.utf8))
    #expect(decoded.scheduledSlotID == nil)
    #expect(decoded.countdownMinutes == 45)
}

@Test func activeSessionRoundTripsScheduledSlotID() throws {
    let slotID = UUID()
    let start = Date(timeIntervalSince1970: 1_700_000_000)
    let exactEnd = start.addingTimeInterval(61)
    let session = ActiveSession(
        mode: .countdown,
        startedAt: start,
        countdownMinutes: 2,
        schedule: nil,
        title: "定时专注",
        scheduledSlotID: slotID,
        scheduledEndAt: exactEnd
    )
    let data = try JSONEncoder().encode(session)
    let decoded = try JSONDecoder().decode(ActiveSession.self, from: data)
    #expect(decoded == session)
    #expect(decoded.scheduledSlotID == slotID)
    #expect(decoded.plannedEnd == exactEnd)
    #expect(decoded.focusSeconds(elapsed: 120) == 61)
}

@Test func hostsRemovalPairsEachBeginWithFollowingEnd() {
    let text = """
    127.0.0.1 localhost
    \(HostsFileEditor.beginMarker)
    127.0.0.1 blocked.example
    \(HostsFileEditor.endMarker)
    \(HostsFileEditor.beginMarker)
    10.0.0.2 keep.example
    """
    let removed = HostsFileEditor.removingBlock(from: text)
    #expect(!removed.contains("blocked.example"))
    #expect(removed.contains("10.0.0.2 keep.example"))
}

@Test func pageClassificationHandlesBlankFragmentsAndInvalidSchemes() {
    #expect(DomainRule.classifyPage("about:blank#blocked") == .ignore)
    #expect(DomainRule.classifyPage("chrome://extensions") == .blocked("chrome:"))
    #expect(DomainRule.classifyPage("https://wikipedia.org@evil.com/path") == .domain("evil.com"))
}
