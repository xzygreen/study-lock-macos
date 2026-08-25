import AppKit
import SwiftUI

/// 菜单栏常驻项(图标 / ⏳ 剩余 / ⏱ 已专注 / ☕ 休息倒计时,点开是今日统计面板)。
///
/// **刻意不用 SwiftUI 的 `MenuBarExtra`**:在 macOS 26/27 上它会自激——每次
/// CoreAnimation 提交都重设一次状态栏项的内容框(`NSSceneStatusItem _setSelectedContentFrame:`),
/// 而每次重设都要同步向渲染服务器申请栅栏
/// (`CAFenceHandle newFenceFromDefaultServer` → 阻塞式 mach_msg)。
/// 实测过:哪怕把标签换成完全静态的图标、下拉内容也不依赖任何状态,主线程仍有约 30%
/// 的时间阻塞在这条路径上,WindowServer 被多吃掉约半个核;整个删掉 MenuBarExtra 后
/// 该开销直接归零。换成原生 NSStatusItem 没有这个问题。
///
/// 两条额外的省事原则:标题只在字符串真正变化时才写;字体用等宽数字,
/// 秒数跳动时宽度不变,连宽度重排都免了。
@MainActor
final class StatusItemController {
    /// 等宽数字 + 菜单栏字号:秒数跳动时状态栏项宽度恒定。
    private static let titleFont = NSFont.monospacedDigitSystemFont(
        ofSize: NSFont.menuBarFont(ofSize: 0).pointSize,
        weight: .regular
    )

    private let item: NSStatusItem
    private let popover = NSPopover()
    private var currentTitle: String?

    init(engine: FocusEngine) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = NSHostingController(
            rootView: MenuBarView(onDismiss: { [weak popover] in
                popover?.performClose(nil)
            })
            .environmentObject(engine)
        )

        item.button?.target = self
        item.button?.action = #selector(togglePopover)
        apply(title: engine.statusBarTitle)

        engine.onStatusBarTitleChange = { [weak self] title in
            self?.apply(title: title)
        }
    }

    private func apply(title: String) {
        guard title != currentTitle, let button = item.button else {
            return
        }
        currentTitle = title
        if title.isEmpty {
            button.attributedTitle = NSAttributedString(string: "")
            button.image = NSImage(
                systemSymbolName: "clock.badge.checkmark",
                accessibilityDescription: "认真"
            )
        } else {
            button.image = nil
            button.attributedTitle = NSAttributedString(
                string: title,
                attributes: [.font: Self.titleFont]
            )
        }
    }

    @objc private func togglePopover() {
        guard let button = item.button else {
            return
        }
        if popover.isShown {
            popover.performClose(nil)
        } else {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        }
    }
}
