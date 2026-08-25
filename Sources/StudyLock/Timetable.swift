import Foundation

/// 单个定时时段。时间用「距当天 0 点的分钟数」表示(跨时区安全、易比较、易持久化)。
/// 判定区间为半开 [startMinute, endMinute):9:45 属于以 9:45 起始的时段,不属于到 9:45 结束的时段,
/// 因此相邻时段(如 9:45 结束→9:45 开始)可无缝衔接。
struct TimeSlot: Codable, Identifiable, Equatable {
    let id: UUID
    var startMinute: Int
    var endMinute: Int

    init(id: UUID = UUID(), startMinute: Int, endMinute: Int) {
        self.id = id
        self.startMinute = startMinute
        self.endMinute = endMinute
    }

    /// 便捷构造:小时/分钟 → 分钟数。
    init(id: UUID = UUID(), startHour: Int, startMin: Int, endHour: Int, endMin: Int) {
        self.init(
            id: id,
            startMinute: startHour * 60 + startMin,
            endMinute: endHour * 60 + endMin
        )
    }

    var isValid: Bool { startMinute < endMinute && startMinute >= 0 && endMinute <= 24 * 60 }

    static func timeText(_ minuteOfDay: Int) -> String {
        String(format: "%02d:%02d", minuteOfDay / 60, minuteOfDay % 60)
    }

    var rangeText: String { "\(Self.timeText(startMinute)) - \(Self.timeText(endMinute))" }
}

/// 定时专注配置:哪些时段自动锁定、哪些星期生效、哪些日期强制跳过/生效。
struct FocusTimetable: Codable, Equatable {
    var isEnabled: Bool
    var slots: [TimeSlot]
    /// Calendar.weekday:1=周日 … 7=周六。默认周一~周五。
    var activeWeekdays: Set<Int>
    /// 强制跳过的日期(startOfDay):法定节假日。
    var skipDates: [Date]
    /// 强制生效的日期(startOfDay):调休补班的周末,即使不在 activeWeekdays 也锁定。
    var forceDates: [Date]

    /// 上表 7 个默认时段。
    static let defaultSlots: [TimeSlot] = [
        TimeSlot(startHour: 9, startMin: 0, endHour: 9, endMin: 45),
        TimeSlot(startHour: 9, startMin: 45, endHour: 10, endMin: 45),
        TimeSlot(startHour: 10, startMin: 55, endHour: 11, endMin: 55),
        TimeSlot(startHour: 13, startMin: 35, endHour: 14, endMin: 45),
        TimeSlot(startHour: 14, startMin: 55, endHour: 15, endMin: 40),
        TimeSlot(startHour: 15, startMin: 45, endHour: 16, endMin: 45),
        TimeSlot(startHour: 17, startMin: 0, endHour: 18, endMin: 5)
    ]

    /// 周一~周五。
    static let defaultWeekdays: Set<Int> = [2, 3, 4, 5, 6]

    static let `default` = FocusTimetable(
        isEnabled: false,
        slots: defaultSlots,
        activeWeekdays: defaultWeekdays,
        skipDates: [],
        forceDates: []
    )

    // 可选字段向后兼容(未来加字段用);当前全部必填,保留显式 Codable 以便演进。
    enum CodingKeys: String, CodingKey {
        case isEnabled, slots, activeWeekdays, skipDates, forceDates
    }

    init(
        isEnabled: Bool,
        slots: [TimeSlot],
        activeWeekdays: Set<Int>,
        skipDates: [Date],
        forceDates: [Date]
    ) {
        self.isEnabled = isEnabled
        self.slots = slots
        self.activeWeekdays = activeWeekdays
        self.skipDates = skipDates
        self.forceDates = forceDates
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? false
        slots = try container.decodeIfPresent([TimeSlot].self, forKey: .slots) ?? Self.defaultSlots
        activeWeekdays = try container.decodeIfPresent(Set<Int>.self, forKey: .activeWeekdays)
            ?? Self.defaultWeekdays
        skipDates = try container.decodeIfPresent([Date].self, forKey: .skipDates) ?? []
        forceDates = try container.decodeIfPresent([Date].self, forKey: .forceDates) ?? []
    }
}

/// 定时专注调度:纯函数,便于单测。
enum TimetableScheduler {
    /// 当天 now 距 0 点的分钟数(截断秒)。
    static func minuteOfDay(_ date: Date, calendar: Calendar = .current) -> Int {
        let components = calendar.dateComponents([.hour, .minute], from: date)
        return (components.hour ?? 0) * 60 + (components.minute ?? 0)
    }

    /// 当天是否生效:forceDates 优先 > skipDates > activeWeekdays。
    static func isActiveDay(
        _ date: Date,
        timetable: FocusTimetable,
        calendar: Calendar = .current
    ) -> Bool {
        let day = calendar.startOfDay(for: date)
        if timetable.forceDates.contains(where: { calendar.isDate($0, inSameDayAs: day) }) {
            return true
        }
        if timetable.skipDates.contains(where: { calendar.isDate($0, inSameDayAs: day) }) {
            return false
        }
        let weekday = calendar.component(.weekday, from: date)
        return timetable.activeWeekdays.contains(weekday)
    }

    /// now 落在哪个时段内。未启用 / 非生效日 / 间隙 → nil。区间为半开 [start, end)。
    static func currentSlot(
        at now: Date,
        timetable: FocusTimetable,
        calendar: Calendar = .current
    ) -> TimeSlot? {
        guard timetable.isEnabled, isActiveDay(now, timetable: timetable, calendar: calendar) else {
            return nil
        }
        let minute = minuteOfDay(now, calendar: calendar)
        return timetable.slots.first { $0.isValid && minute >= $0.startMinute && minute < $0.endMinute }
    }

    /// 今天下一个尚未开始的时段(startMinute 严格大于当前分钟)。无则 nil。
    static func nextSlot(
        after now: Date,
        timetable: FocusTimetable,
        calendar: Calendar = .current
    ) -> TimeSlot? {
        guard timetable.isEnabled, isActiveDay(now, timetable: timetable, calendar: calendar) else {
            return nil
        }
        let minute = minuteOfDay(now, calendar: calendar)
        return timetable.slots
            .filter { $0.isValid && $0.startMinute > minute }
            .min { $0.startMinute < $1.startMinute }
    }

    /// 时段到结束还剩多少秒(now 在时段内时为正)。
    static func remainingSeconds(
        in slot: TimeSlot,
        at now: Date,
        calendar: Calendar = .current
    ) -> Int {
        let startOfDay = calendar.startOfDay(for: now)
        let slotEnd = startOfDay.addingTimeInterval(TimeInterval(slot.endMinute * 60))
        return Int(slotEnd.timeIntervalSince(now))
    }

    /// 所有时段合法(start<end)且按时间互不重叠。
    static func validate(slots: [TimeSlot]) -> Bool {
        guard slots.allSatisfy(\.isValid) else {
            return false
        }
        let sorted = slots.sorted { $0.startMinute < $1.startMinute }
        for (previous, next) in zip(sorted, sorted.dropFirst()) where next.startMinute < previous.endMinute {
            return false
        }
        return true
    }

    /// 「今天该时段不再自动重启」的去重键。
    static func dismissKey(
        slotID: UUID,
        on date: Date,
        calendar: Calendar = .current
    ) -> String {
        "\(slotID.uuidString)|\(dayKey(date, calendar: calendar))"
    }

    /// 键是否属于 date 当天(用于加载时清掉隔日旧键)。
    static func keyIsForDay(_ key: String, date: Date, calendar: Calendar = .current) -> Bool {
        key.hasSuffix("|" + dayKey(date, calendar: calendar))
    }

    private static func dayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", components.year ?? 0, components.month ?? 0, components.day ?? 0)
    }
}
