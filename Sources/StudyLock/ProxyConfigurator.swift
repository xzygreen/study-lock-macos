import Foundation

/// v2.3 曾把系统代理指向本地过滤代理;v2.4 起改用浏览器标签监控,不再接管系统代理。
/// 本类仅保留 restore:把此前可能被 v2.3 改动、且异常退出未还原的系统代理还原回去。
@MainActor
enum ProxyConfigurator {
    private nonisolated static let networksetup = "/usr/sbin/networksetup"

    /// 按快照逐项还原各网络服务的代理设置。返回是否全部成功。
    nonisolated static func restore(_ snapshot: ProxySnapshot) -> Bool {
        var allOK = true
        for service in snapshot.services {
            let name = service.serviceName
            if service.webProxyEnabled, !service.webProxyHost.isEmpty {
                allOK = run(["-setwebproxy", name, service.webProxyHost, "\(service.webProxyPort)"]) && allOK
                allOK = run(["-setwebproxystate", name, "on"]) && allOK
            } else {
                allOK = run(["-setwebproxystate", name, "off"]) && allOK
            }
            if service.secureWebProxyEnabled, !service.secureWebProxyHost.isEmpty {
                allOK = run([
                    "-setsecurewebproxy", name,
                    service.secureWebProxyHost, "\(service.secureWebProxyPort)"
                ]) && allOK
                allOK = run(["-setsecurewebproxystate", name, "on"]) && allOK
            } else {
                allOK = run(["-setsecurewebproxystate", name, "off"]) && allOK
            }
            if service.autoProxyEnabled, !service.autoProxyURL.isEmpty {
                allOK = run(["-setautoproxyurl", name, service.autoProxyURL]) && allOK
                allOK = run(["-setautoproxystate", name, "on"]) && allOK
            }
        }
        return allOK
    }

    @discardableResult
    private nonisolated static func run(_ arguments: [String]) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: networksetup)
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        return process.terminationStatus == 0
    }
}
