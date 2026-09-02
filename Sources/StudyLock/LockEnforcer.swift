import AppKit
import Foundation

/// 隐藏式锁定引擎:非白名单应用被立即隐藏并把焦点弹回本应用,
/// 不结束进程;解锁时恢复被隐藏的应用。
@MainActor
final class LockEnforcer {
    private var observers: [NSObjectProtocol] = []
    private var scanTimer: Timer?
    private var whitelist: Set<String> = []
    /// 被本引擎隐藏的应用身份,解锁时校验后 unhide 恢复。
    private var hiddenByUs: [pid_t: HiddenApplicationIdentity] = [:]
    var onBlocked: ((String) -> Void)?
    var onHiddenAppsChanged: (([HiddenApplicationIdentity]) -> Void)?

    var isRunning: Bool { scanTimer != nil }

    func start(
        whitelist: Set<String>,
        previouslyHidden: [HiddenApplicationIdentity] = []
    ) {
        self.whitelist = whitelist
        for identity in previouslyHidden {
            hiddenByUs[pid_t(identity.processIdentifier)] = identity
        }
        guard scanTimer == nil else {
            enforceNow()
            return
        }

        let center = NSWorkspace.shared.notificationCenter
        for name in [
            NSWorkspace.didLaunchApplicationNotification,
            NSWorkspace.didActivateApplicationNotification,
            NSWorkspace.didUnhideApplicationNotification
        ] {
            let observer = center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard
                    let app = notification.userInfo?[
                        NSWorkspace.applicationUserInfoKey
                    ] as? NSRunningApplication
                else {
                    return
                }
                Task { @MainActor in
                    guard let self else { return }
                    if self.blockIfNeeded(app) {
                        self.publishHiddenApps()
                    }
                }
            }
            observers.append(observer)
        }

        scanTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                self?.enforceNow()
            }
        }
        enforceNow()
    }

    func updateWhitelist(_ whitelist: Set<String>) {
        self.whitelist = whitelist
        if scanTimer != nil {
            enforceNow()
        }
    }

    func stop() {
        scanTimer?.invalidate()
        scanTimer = nil
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
        observers.removeAll()
        restoreHiddenApps()
    }

    private func enforceNow() {
        var changed = false
        for app in NSWorkspace.shared.runningApplications where blockIfNeeded(app) {
            changed = true
        }
        if changed { publishHiddenApps() }
    }

    @discardableResult
    private func blockIfNeeded(_ app: NSRunningApplication) -> Bool {
        guard app.activationPolicy == .regular, !app.isTerminated else {
            return false
        }

        let isAllowed = LockPolicy.allows(
            bundleIdentifier: app.bundleIdentifier,
            bundleURL: app.bundleURL,
            processIdentifier: app.processIdentifier,
            ownProcessIdentifier: ProcessInfo.processInfo.processIdentifier,
            whitelist: whitelist
        )
        guard !isAllowed else {
            return false
        }

        let wasFrontmost = app.isActive
        var changed = false
        if !app.isHidden {
            // hide() 的返回值不可靠(可能返回 false 但已生效),以 isHidden 为准。
            app.hide()
            hiddenByUs[app.processIdentifier] = HiddenApplicationIdentity(app)
            changed = true
            onBlocked?(app.localizedName ?? "未命名应用")
        }
        // 只在焦点确实被抢走时才抢回来。隐藏后系统通常已把前台交还给我们,
        // 此时再无条件 activate 会让 WindowServer 反复重排窗口层级
        // (macOS 26 起窗口/菜单栏走 scene 托管,这个代价比以前高得多)。
        if wasFrontmost, !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        return changed
    }

    func restore(previouslyHidden: [HiddenApplicationIdentity]) {
        for identity in previouslyHidden {
            hiddenByUs[pid_t(identity.processIdentifier)] = identity
        }
        restoreHiddenApps()
    }

    private func restoreHiddenApps() {
        for (pid, identity) in hiddenByUs {
            guard let app = NSRunningApplication(processIdentifier: pid),
                  !app.isTerminated, app.isHidden, identity.matches(app) else { continue }
            app.unhide()
        }
        hiddenByUs.removeAll()
        publishHiddenApps()
    }

    private func publishHiddenApps() {
        onHiddenAppsChanged?(Array(hiddenByUs.values))
    }

    deinit {
        scanTimer?.invalidate()
        let center = NSWorkspace.shared.notificationCenter
        observers.forEach(center.removeObserver)
    }
}
