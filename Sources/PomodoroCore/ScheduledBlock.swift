import Foundation

/// One entry in the day's timeline: a work block, a break, or a meeting.
public struct ScheduledBlock: Identifiable, Hashable, Sendable {
    public enum Kind: String, Hashable, Sendable {
        case work
        case shortBreak
        case longBreak
        case meeting
    }

    public let id: String
    public let kind: Kind
    public let title: String
    public let start: Date
    public let end: Date
    /// Set for work and break blocks; `nil` for meetings.
    public let taskID: UUID?
    /// Whether the owning task is already complete.
    public let isDone: Bool
    /// For meetings, the calendar it came from.
    public let calendarName: String?
    /// For meetings, the event's description / notes field.
    public let notes: String?
    /// True for all-day calendar events, which span midnight to midnight.
    public let isAllDay: Bool

    public init(
        id: String,
        kind: Kind,
        title: String,
        start: Date,
        end: Date,
        taskID: UUID?,
        isDone: Bool,
        calendarName: String? = nil,
        notes: String? = nil,
        isAllDay: Bool = false
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.start = start
        self.end = end
        self.taskID = taskID
        self.isDone = isDone
        self.calendarName = calendarName
        self.notes = notes
        self.isAllDay = isAllDay
    }

    public var duration: TimeInterval { end.timeIntervalSince(start) }
    public var minutes: Int { Int((duration / 60).rounded()) }

    public var isBreak: Bool {
        kind == .shortBreak || kind == .longBreak
    }

    public var isMeeting: Bool { kind == .meeting }

    /// True for blocks the user can run a countdown on (work and meetings).
    ///
    /// All-day events are excluded: they span roughly 24 hours, so offering a
    /// countdown on one produces a meaningless "1440:00" timer.
    public var isFocus: Bool {
        kind == .work || (kind == .meeting && !isAllDay)
    }
}
