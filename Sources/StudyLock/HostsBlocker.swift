import Foundation

/// v2.1 曾用 /etc/hosts 屏蔽网站(黑名单);v2.2 改为浏览器标签白名单监控。
/// 本类仅保留启动清理能力:发现残留的标记块时请求管理员权限移除。
@MainActor
final class HostsBlocker {
    nonisolated static let hostsPath = "/etc/hosts"

    /// /etc/hosts 是否残留我们的标记块(全局可读,无需特权)。
    nonisolated static func hostsContainsBlock() -> Bool {
        guard let contents = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
            return false
        }
        return HostsFileEditor.containsBlock(contents)
    }

    /// 移除屏蔽块。hosts 里本来就没有块时直接成功(零密码框)。
    func removeBlock(completion: @escaping @MainActor (Bool) -> Void) {
        Task.detached(priority: .userInitiated) {
            let success = Self.performRemoval()
            await completion(success)
        }
    }

    private nonisolated static func performRemoval() -> Bool {
        guard let current = try? String(contentsOfFile: hostsPath, encoding: .utf8) else {
            return false
        }
        guard HostsFileEditor.containsBlock(current) else {
            return true
        }
        let updated = HostsFileEditor.removingBlock(from: current)

        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("studylock-hosts-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: temporaryURL)
        }
        do {
            try updated.write(to: temporaryURL, atomically: true, encoding: .utf8)
        } catch {
            return false
        }

        // /bin/cp 保留 /etc/hosts 原属主与权限(直接 mv 会带来临时目录的属性)。
        let shell = "/bin/cp '\(temporaryURL.path)' '\(hostsPath)'"
            + " && /usr/bin/dscacheutil -flushcache"
            + " && /usr/bin/killall -HUP mDNSResponder"
        let script = "do shell script \"\(shell)\" with administrator privileges"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        process.arguments = ["-e", script]
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        // 非零退出码含用户取消密码框(-128)。
        return process.terminationStatus == 0
    }
}
