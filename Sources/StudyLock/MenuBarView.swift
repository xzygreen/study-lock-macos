import AppKit
import SwiftUI

struct MenuBarView: View {
    /// 点「打开主窗口」后关掉这个面板;默认空实现,方便预览与测试。
    var onDismiss: () -> Void = {}

    @EnvironmentObject private var engine: FocusEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Circle()
                    .fill(engine.isLockEnabled ? Color.danger : Color.success)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.system(size: 13, weight: .semibold))
                Spacer()
                Image(systemName: engine.isLockEnabled ? "lock.fill" : "lock.open")
                    .foregroundStyle(.secondary)
            }

            if engine.isSessionActive {
                VStack(alignment: .leading, spacing: 4) {
                    Text(engine.primaryTimeText)
                        .font(.system(size: 30, weight: .semibold, design: .monospaced))
                        .foregroundStyle(engine.isInPomodoroRest ? Color.rest : Color.primary)
                    Text(sessionDetailText)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            } else {
                VStack(alignment: .leading, spacing: 4) {
                    Text(
                        engine.now.formatted(
                            .dateTime.hour(.twoDigits(amPM: .omitted))
                                .minute(.twoDigits)
                                .second(.twoDigits)
                        )
                    )
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    if engine.timetable.isEnabled, let slot = engine.nextScheduledSlot {
                        Text("下一时段 \(slot.rangeText)")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Divider()

            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(engine.todayFocusedMinutes)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("今日分钟")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(engine.todayCompletedSessionCount)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                    Text("今日完成")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(engine.streakDays)")
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            engine.streakDays > 0 && !engine.hasCompletedToday
                                ? Color.danger
                                : Color.primary
                        )
                    Text("连续天数")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()

            Button {
                openMainWindow()
            } label: {
                Label("打开主窗口", systemImage: "macwindow")
                    .font(.system(size: 12, weight: .medium))
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .background(Color.brand.opacity(0.1), in: RoundedRectangle(cornerRadius: 7))
                    .foregroundStyle(Color.brand)
            }
            .buttonStyle(.plain)
        }
        .padding(16)
        .frame(width: 240)
    }

    private var statusText: String {
        guard let session = engine.session else {
            return engine.isLockEnabled ? "手动锁定中" : "空闲"
        }
        switch session.mode {
        case .countdown:
            return "倒计时专注中"
        case .countUp:
            return "正计时专注中"
        case .pomodoro:
            switch engine.pomodoroPhase {
            case .focus(let round, _):
                return "番茄第 \(round) 轮 · 专注"
            case .rest(let round, _):
                return "番茄第 \(round) 轮 · 休息"
            default:
                return "番茄钟"
            }
        }
    }

    private var sessionDetailText: String {
        guard let session = engine.session else {
            return ""
        }
        let focused = DurationFormatter.elapsed(engine.sessionFocusSeconds)
        if session.title.isEmpty {
            return "本次已专注 \(focused)"
        }
        return "\(session.title) · 已专注 \(focused)"
    }

    private func openMainWindow() {
        onDismiss()
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeMain {
            window.makeKeyAndOrderFront(nil)
        }
    }
}
