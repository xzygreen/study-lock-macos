import AppKit
import SwiftUI

@main
struct StudyLockApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var engine = FocusEngine()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(engine)
                .frame(minWidth: 980, minHeight: 680)
                .onAppear {
                    appDelegate.attach(engine: engine)
                    NSApp.applicationIconImage = AppIcon.image
                }
        }
        .windowStyle(.hiddenTitleBar)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }
        // 菜单栏项由 StatusItemController(原生 NSStatusItem)负责,
        // 不用 MenuBarExtra——原因见 StatusItemController 注释。
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var engine: FocusEngine?
    private var statusItem: StatusItemController?

    /// 主窗口首次出现时接上引擎并建菜单栏项(只做一次)。
    func attach(engine: FocusEngine) {
        guard self.engine == nil else {
            return
        }
        self.engine = engine
        statusItem = StatusItemController(engine: engine)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 锁定期间退出应用需输入动态确认短语,防止用 Cmd+Q 绕过锁定。
    /// 确认后先落记录、清快照、移除网站屏蔽,再放行退出(否则下次启动会误判强退)。
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let engine, engine.isLockEnabled else {
            return .terminateNow
        }

        let phrase = ExitConfirmation.randomPhrase(
            now: Date(),
            focusedMinutes: engine.isSessionActive
                ? Int(engine.sessionFocusSeconds / 60)
                : nil
        )

        let alert = NSAlert()
        alert.messageText = "专注仍在进行"
        alert.informativeText = "退出「认真」会解除应用锁定。如确定要退出,请一字不差地输入:\n\(phrase)"
        alert.alertStyle = .warning

        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = "在此输入上面这句话"
        alert.accessoryView = field
        alert.window.initialFirstResponder = field

        alert.addButton(withTitle: "退出并解锁")
        alert.addButton(withTitle: "继续专注")

        let response = alert.runModal()
        guard
            response == .alertFirstButtonReturn,
            ExitConfirmation.matches(field.stringValue, phrase: phrase)
        else {
            return .terminateCancel
        }
        engine.prepareForConfirmedQuit {
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}

enum AppIcon {
    static var image: NSImage {
        let size = NSSize(width: 512, height: 512)
        let image = NSImage(size: size)
        image.lockFocus()

        let bounds = NSRect(origin: .zero, size: size)
        let background = NSBezierPath(
            roundedRect: bounds.insetBy(dx: 20, dy: 20),
            xRadius: 112,
            yRadius: 112
        )
        NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.18, alpha: 1).setFill()
        background.fill()

        let dial = NSBezierPath(
            ovalIn: NSRect(x: 106, y: 106, width: 300, height: 300)
        )
        NSColor(calibratedRed: 0.94, green: 0.97, blue: 0.96, alpha: 1).setFill()
        dial.fill()

        let center = NSPoint(x: 256, y: 256)
        let hand = NSBezierPath()
        hand.lineCapStyle = .round
        hand.lineWidth = 26
        hand.move(to: center)
        hand.line(to: NSPoint(x: 256, y: 342))
        hand.move(to: center)
        hand.line(to: NSPoint(x: 326, y: 218))
        NSColor(calibratedRed: 0.15, green: 0.55, blue: 0.43, alpha: 1).setStroke()
        hand.stroke()

        let hub = NSBezierPath(ovalIn: NSRect(x: 239, y: 239, width: 34, height: 34))
        NSColor(calibratedRed: 0.12, green: 0.16, blue: 0.18, alpha: 1).setFill()
        hub.fill()

        image.unlockFocus()
        return image
    }
}
