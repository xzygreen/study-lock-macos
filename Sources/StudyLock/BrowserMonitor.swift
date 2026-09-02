import AppKit
import Foundation

/// 专注期间的浏览器网页执法与时长统计——工作在浏览器脚本层(AppleScript),
/// 在系统代理/VPN(含 Clash TUN)之上,不受任何网络配置影响。
///
/// 锁定期间每 2 秒:
/// - 遍历所有正在运行的受支持浏览器(Safari/Chrome/Edge/Arc/Brave)的每个窗口每个标签,
///   非白名单网页立即导航到 about:blank(含后台标签);
/// - 前台浏览器的活动标签用于网站时长与分心判定。
///
/// 性能约束(macOS 26/27 上尤其要命,详见 AppleScriptRunner 注释):
/// - **脚本一律不在主线程跑**,全部交给 AppleScriptRunner,本类只 await;
/// - **一个窗口一次 Apple 事件**(`URL of every tab of window`),不再逐标签往返;
/// - 固定源码的脚本缓存编译结果,并统一加 `with timeout`,防止浏览器卡死时挂住执法线程。
///
/// AppleScript 需要「自动化」权限,首次执行系统会弹授权;被拒时回调
/// onPermissionDenied(每个浏览器只报一次)。
@MainActor
final class BrowserMonitor {
    /// 采样/执法间隔(秒);由外部时钟按此周期调用 enforce()。
    static let sampleInterval = 2

    /// 单条脚本的时限;AppleScript 默认 120 秒,浏览器一卡就把执法线程挂死。
    private static let scriptTimeoutSeconds = 10

    var onPermissionDenied: (() -> Void)?

    /// 一轮扫描结果。
    struct SweepResult {
        /// 本轮被导离的全部域名(去重,用于记录与报告)。
        var blockedDomains: Set<String> = []
        /// 前台浏览器活动标签命中的非白名单域名(用于分心计数+横幅)。
        var activeBlocked: String?
        /// 前台浏览器活动标签命中的白名单域名(用于网站时长)。
        var activeAllowed: String?
    }

    private let runner = AppleScriptRunner()
    private var deniedBrowsers: Set<String> = []
    private var isSweeping = false

    /// 扫描并执法一轮,返回被拦域名与前台命中。整轮不阻塞主线程。
    func enforce(allowedDomains: Set<String>) async -> SweepResult {
        // 重入保护:上一轮还没跑完就跳过,避免堆积。
        guard !isSweeping else {
            return SweepResult()
        }
        isSweeping = true
        defer { isSweeping = false }

        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        var result = SweepResult()

        for browser in runningBrowsers() {
            guard let name = browser.app.localizedName else {
                continue
            }
            let single = await sweep(
                browserName: name,
                dialect: browser.dialect,
                isFrontmost: browser.app.processIdentifier == frontmostPID,
                allowedDomains: allowedDomains
            )
            result.blockedDomains.formUnion(single.blockedDomains)
            result.activeBlocked = result.activeBlocked ?? single.activeBlocked
            result.activeAllowed = result.activeAllowed ?? single.activeAllowed
        }
        return result
    }

    /// 权限修复后允许重新提示。
    func resetPermissionState() {
        deniedBrowsers.removeAll()
    }

    // MARK: - 单浏览器扫描

    private struct RunningBrowser {
        let app: NSRunningApplication
        let dialect: BrowserPolicy.Dialect
    }

    private func runningBrowsers() -> [RunningBrowser] {
        NSWorkspace.shared.runningApplications.compactMap { app in
            guard
                !app.isTerminated,
                let dialect = BrowserPolicy.dialect(for: app.bundleIdentifier)
            else {
                return nil
            }
            return RunningBrowser(app: app, dialect: dialect)
        }
    }

    private func sweep(
        browserName: String,
        dialect: BrowserPolicy.Dialect,
        isFrontmost: Bool,
        allowedDomains: Set<String>
    ) async -> SweepResult {
        var result = SweepResult()

        // 全窗口全标签:查 URL 列表。权限被拒在此统一捕获。
        let listing = await runner.run(
            allTabsSource(browserName),
            cacheKey: "tabs:\(browserName)"
        )
        switch listing {
        case .permissionDenied:
            reportDenied(browserName)
            return result
        case .unavailable:
            return result
        case .value(let text):
            var redirects: [(window: Int, tab: Int)] = []
            for line in text.split(separator: "\n") {
                let parts = line.split(separator: ",", maxSplits: 2).map(String.init)
                guard
                    parts.count == 3,
                    let window = Int(parts[0]),
                    let tab = Int(parts[1])
                else {
                    continue
                }
                switch DomainRule.classifyPage(parts[2]) {
                case .ignore:
                    continue
                case .domain(let domain):
                    if !DomainRule.isAllowed(domain, whitelist: allowedDomains) {
                        redirects.append((window, tab))
                        result.blockedDomains.insert(domain)
                    }
                case .blocked(let category):
                    redirects.append((window, tab))
                    result.blockedDomains.insert(category)
                }
            }
            if !redirects.isEmpty {
                _ = await runner.run(redirectSource(browserName, tabs: redirects))
            }
        }

        // 前台浏览器:活动标签用于时长/分心判定。
        guard isFrontmost,
              case .value(let raw) = await runner.run(
                  activeTabSource(browserName, dialect),
                  cacheKey: "active:\(browserName)"
              ) else {
            return result
        }
        switch DomainRule.classifyPage(raw) {
        case .ignore:
            break
        case .domain(let domain):
            if DomainRule.isAllowed(domain, whitelist: allowedDomains) {
                result.activeAllowed = domain
            } else {
                result.activeBlocked = domain
            }
        case .blocked(let category):
            result.activeBlocked = category
        }
        return result
    }

    private func reportDenied(_ browserName: String) {
        if deniedBrowsers.insert(browserName).inserted {
            onPermissionDenied?()
        }
    }

    // MARK: - AppleScript 源码

    private func activeTabSource(_ app: String, _ dialect: BrowserPolicy.Dialect) -> String {
        let tab = dialect == .safari ? "current tab" : "active tab"
        return """
        with timeout of \(Self.scriptTimeoutSeconds) seconds
            tell application "\(app)"
                if (count of windows) is 0 then return ""
                return URL of \(tab) of front window
            end tell
        end timeout
        """
    }

    /// 返回每行 `窗口序,标签序,URL`。
    ///
    /// 关键:`URL of every tab of <window>` 一次 Apple 事件取回整窗口的 URL 列表,
    /// 之后的 repeat 只在脚本内部遍历本地列表。旧写法 `URL of tab ti of window wi`
    /// 是**每个标签一次跨进程往返**,几十个标签就要几十次,是卡顿的主要来源之一。
    /// Safari 与 Chromium 系的这条语法一致,无需分方言。
    private func allTabsSource(_ app: String) -> String {
        """
        set rows to {}
        with timeout of \(Self.scriptTimeoutSeconds) seconds
            tell application "\(app)"
                set wins to every window
                repeat with wi from 1 to (count of wins)
                    try
                        set tabURLs to URL of every tab of (item wi of wins)
                    on error
                        set tabURLs to {}
                    end try
                    repeat with ti from 1 to (count of tabURLs)
                        set u to item ti of tabURLs
                        if u is missing value then set u to ""
                        set end of rows to (wi as text) & "," & (ti as text) & "," & (u as text)
                    end repeat
                end repeat
            end tell
        end timeout
        set AppleScript's text item delimiters to linefeed
        return rows as text
        """
    }

    /// 逐标签清空;单条失败(标签已关等)不影响其余,故各自 try。
    private func redirectSource(_ app: String, tabs: [(window: Int, tab: Int)]) -> String {
        let commands = tabs
            .map {
                """
                try
                    set URL of tab \($0.tab) of window \($0.window) to "about:blank"
                end try
                """
            }
            .joined(separator: "\n")
        return """
        with timeout of \(Self.scriptTimeoutSeconds) seconds
            tell application "\(app)"
                \(commands)
            end tell
        end timeout
        """
    }
}
