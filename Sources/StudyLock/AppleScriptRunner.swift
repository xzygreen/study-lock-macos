import Foundation

/// AppleScript 一次执行的结果。
enum ScriptOutcome {
    case value(String)
    /// 自动化权限被拒(errAEEventNotPermitted)。
    case permissionDenied
    /// 编译失败、目标应用没响应、超时等——本轮拿不到数据,静默跳过。
    case unavailable
}

/// 常驻后台线程,串行执行全部 AppleScript。
///
/// **必须离开主线程**:NSAppleScript 等待 Apple 事件回复期间,会经
/// `AEDefaultActiveProc → WaitNextEvent` 驱动一个嵌套 Carbon 事件循环,一秒转几百圈。
/// macOS 26 起菜单栏项改由 MenuBarAgent 以 scene(FBSScene)托管,每次 CoreAnimation
/// 提交都要向渲染服务器同步申请栅栏(`CAFenceHandle newFenceFromDefaultServer` → mach_msg),
/// 于是每转一圈就同步问一次 WindowServer——主线程被占死、WindowServer 被打满,整机卡顿。
/// 放到自己的线程上,等待就只是一次普通的 mach_msg 阻塞,不触碰任何 UI。
///
/// 线程自带 runloop:Apple 事件的回复投递依赖它,`perform(on:)` 派发也依赖它。
final class AppleScriptRunner: @unchecked Sendable {
    private let worker = Worker()

    init() {
        worker.name = "cn.local.studylock.applescript"
        worker.qualityOfService = .utility
        worker.start()
        worker.waitUntilReady()
    }

    /// 在专用线程上执行脚本;await 期间主线程完全空闲。
    /// - Parameter cacheKey: 非 nil 时复用已编译脚本(源码固定的脚本用,省掉每轮重新编译)。
    func run(_ source: String, cacheKey: String? = nil) async -> ScriptOutcome {
        await withCheckedContinuation { continuation in
            worker.submit { [worker] in
                continuation.resume(returning: worker.execute(source, cacheKey: cacheKey))
            }
        }
    }
}

/// 把闭包装成 objc 对象,好走 `perform(_:on:with:waitUntilDone:)`。
private final class Job: NSObject, @unchecked Sendable {
    let work: () -> Void

    init(_ work: @escaping () -> Void) {
        self.work = work
    }
}

private final class Worker: Thread, @unchecked Sendable {
    /// errAEEventNotPermitted:用户在「自动化」里拒绝了授权。
    private static let notPermittedError = -1743

    /// 已编译脚本缓存;只在本线程访问,故无需加锁。
    private var compiled: [String: NSAppleScript] = [:]
    private let ready = DispatchSemaphore(value: 0)

    override func main() {
        let runLoop = RunLoop.current
        // 挂一个空端口:否则 runloop 无源会立刻返回,退化成空转。
        runLoop.add(NSMachPort(), forMode: .default)
        ready.signal()
        while !isCancelled {
            autoreleasepool {
                _ = runLoop.run(mode: .default, before: .distantFuture)
            }
        }
    }

    /// 等 runloop 就绪再派发,避免启动竞态丢消息。
    func waitUntilReady() {
        _ = ready.wait(timeout: .now() + 2)
    }

    func submit(_ work: @escaping () -> Void) {
        perform(
            #selector(runJob(_:)),
            on: self,
            with: Job(work),
            waitUntilDone: false
        )
    }

    @objc private func runJob(_ job: Job) {
        autoreleasepool {
            job.work()
        }
    }

    /// 只在本线程调用。
    func execute(_ source: String, cacheKey: String?) -> ScriptOutcome {
        let script: NSAppleScript
        if let cacheKey, let cached = compiled[cacheKey] {
            script = cached
        } else if let fresh = NSAppleScript(source: source) {
            script = fresh
            if let cacheKey {
                compiled[cacheKey] = fresh
            }
        } else {
            return .unavailable
        }

        var error: NSDictionary?
        let output = script.executeAndReturnError(&error)
        if let error {
            let code = error[NSAppleScript.errorNumber] as? Int
            return code == Self.notPermittedError ? .permissionDenied : .unavailable
        }
        return .value(output.stringValue ?? "")
    }
}
