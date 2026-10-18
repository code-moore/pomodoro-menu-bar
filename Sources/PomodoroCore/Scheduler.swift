import Foundation

/// Lays out the day: splits each task into Pomodoro work blocks with breaks
/// between them, pins meetings at their real times, and pushes any work block
/// that would collide with a meeting to after that meeting ends.
///
/// Everything here is a pure function of its inputs. There is no `Date()`, no
/// I/O, and no calendar access, so the layout can be unit tested exactly.
public enum Scheduler {
    /// A break's name in the plan and the menu bar.
    static func breakTitle(isLong: Bool) -> String {
        isLong
            ? String(localized: "Long break", comment: "A break's name in the day's plan and the menu bar.")
            : String(localized: "Break", comment: "A short break's name in the day's plan and the menu bar.")
    }

    /// Hard ceiling on a single task's estimate.
    ///
    /// Applied here as well as at the UI layer, so a pathological value that
    /// arrives some other way — hand-edited preferences, older saved history —
    /// still can't generate thousands of timeline blocks.
    public static let maxTaskMinutes = 600

    public struct Settings: Hashable, Sendable {
        public var workMinutes: Int
        public var shortBreakMinutes: Int
        public var longBreakMinutes: Int
        public var pomodorosBeforeLongBreak: Int

        public init(
            workMinutes: Int = 25,
            shortBreakMinutes: Int = 5,
            longBreakMinutes: Int = 15,
            pomodorosBeforeLongBreak: Int = 4
        ) {
            self.workMinutes = max(1, workMinutes)
            self.shortBreakMinutes = max(0, shortBreakMinutes)
            self.longBreakMinutes = max(0, longBreakMinutes)
            self.pomodorosBeforeLongBreak = max(1, pomodorosBeforeLongBreak)
        }
    }

    /// The break owed after a work block that ran to the end. It is laid out
    /// ahead of everything else, so finishing a block doesn't skip its break.
    public struct PendingBreak: Hashable, Sendable {
        /// When the break begins on the timeline.
        public var start: Date
        public var isLong: Bool
        /// Stays the same however often the day is rebuilt, so the break can
        /// be counted down like any other block.
        public var id: String
        /// An already-started break keeps its duration when settings change.
        public var minutes: Int?

        public init(start: Date, isLong: Bool, id: String, minutes: Int? = nil) {
            self.start = start
            self.isLong = isLong
            self.id = id
            self.minutes = minutes
        }
    }

    /// The timeline id a meeting's block is given, so callers can find its row.
    public static func blockID(for meeting: Meeting) -> ScheduledBlock.ID {
        "meeting-\(meeting.id)"
    }

    /// The timeline id of a task's work block. Blocks number on from the ones
    /// already finished, so the next to run is `completedBlocks + 1`.
    public static func workBlockID(taskID: UUID, number: Int) -> ScheduledBlock.ID {
        "\(taskID.uuidString)-work-\(number)"
    }

    /// The task a work block belongs to, read back from its id.
    public static func taskID(forWorkBlock id: ScheduledBlock.ID) -> UUID? {
        guard let range = id.range(of: "-work-") else { return nil }
        return UUID(uuidString: String(id[..<range.lowerBound]))
    }

    /// The order tasks are worked through: most urgent first, and in the
    /// order they were added within a level.
    public static func ordered(_ tasks: [DayTask]) -> [DayTask] {
        tasks.enumerated()
            .sorted { lhs, rhs in
                if lhs.element.priority != rhs.element.priority {
                    return lhs.element.priority < rhs.element.priority
                }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    /// Builds the timeline for one day.
    ///
    /// - Parameters:
    ///   - tasks: in the order they were added. They are laid out most urgent
    ///     first (see `ordered`), and only the part of each that hasn't been
    ///     worked yet. Completed tasks are still laid out so the day's plan
    ///     stays stable.
    ///   - meetings: fixed commitments. All-day events are ignored for
    ///     scheduling (they block nothing) but are still returned.
    ///   - dayStart: when the first task may begin.
    ///   - pendingBreak: a break owed from a finished block, which goes first.
    ///   - firstTaskID: the task being worked on now. Its next block goes
    ///     first, exactly at `dayStart`, so a more urgent task added meanwhile
    ///     waits for that block to end rather than cutting it short. The rest
    ///     of the task keeps its place in the priority order.
    ///   - firstBlockMinutes: the started block's frozen duration, if present.
    ///     Only subsequent chunks use the current work-duration setting.
    ///   - completedPomodoros: work blocks already finished today, so the long
    ///     break still comes after every fourth.
    public static func buildDay(
        tasks: [DayTask],
        meetings: [Meeting],
        dayStart: Date,
        settings: Settings = Settings(),
        pendingBreak: PendingBreak? = nil,
        firstTaskID: DayTask.ID? = nil,
        firstBlockMinutes: Int? = nil,
        completedPomodoros: Int = 0,
        calendar: Calendar = .current
    ) -> [ScheduledBlock] {
        let timedMeetings = meetings
            .filter { !$0.isAllDay }
            .sorted { $0.start < $1.start }

        var blocks: [ScheduledBlock] = []
        var cursor = dayStart
        var pomodoroCount = max(0, completedPomodoros)

        if let pendingBreak {
            let length = pendingBreak.minutes ?? (pendingBreak.isLong ? settings.longBreakMinutes : settings.shortBreakMinutes)
            if length > 0 {
                let end = adding(minutes: length, to: pendingBreak.start, calendar: calendar)
                blocks.append(ScheduledBlock(
                    id: pendingBreak.id,
                    kind: pendingBreak.isLong ? .longBreak : .shortBreak,
                    title: Self.breakTitle(isLong: pendingBreak.isLong),
                    start: pendingBreak.start,
                    end: end,
                    taskID: nil,
                    isDone: false
                ))
                cursor = max(cursor, end)
            }
        }

        // Every work block still to do, in the order they'll be worked.
        var queue: [Chunk] = []
        var pinnedRest: [Chunk] = []
        if let firstTaskID, let first = tasks.first(where: { $0.id == firstTaskID }) {
            let chunks = Self.chunks(of: first, settings: settings, firstMinutes: firstBlockMinutes)
            queue += chunks.prefix(1)
            pinnedRest = Array(chunks.dropFirst())
        }
        for task in ordered(tasks) {
            if task.id == firstTaskID && !queue.isEmpty {
                queue += pinnedRest
            } else {
                queue += Self.chunks(of: task, settings: settings)
            }
        }

        for (index, chunk) in queue.enumerated() {
            let task = chunk.task
            // The block under way stays where it is, even across a meeting:
            // it's already being counted down.
            let isPinned = index == 0 && firstTaskID != nil && task.id == firstTaskID
            if !isPinned {
                cursor = firstFreeSlot(
                    from: cursor, minutes: chunk.minutes,
                    meetings: timedMeetings, calendar: calendar
                )
            }
            let workEnd = adding(minutes: chunk.minutes, to: cursor, calendar: calendar)

            blocks.append(ScheduledBlock(
                id: workBlockID(taskID: task.id, number: chunk.number),
                kind: .work,
                title: task.title,
                start: cursor,
                end: workEnd,
                taskID: task.id,
                isDone: task.isDone
            ))
            cursor = workEnd
            pomodoroCount += 1

            // A break follows every pomodoro, including the last one of a task.
            let isLong = pomodoroCount % settings.pomodorosBeforeLongBreak == 0
            let breakLength = isLong ? settings.longBreakMinutes : settings.shortBreakMinutes
            guard breakLength > 0 else { continue }

            cursor = firstFreeSlot(
                from: cursor, minutes: breakLength,
                meetings: timedMeetings, calendar: calendar
            )
            let breakEnd = adding(minutes: breakLength, to: cursor, calendar: calendar)

            blocks.append(ScheduledBlock(
                id: "\(task.id.uuidString)-break-\(chunk.number)",
                kind: isLong ? .longBreak : .shortBreak,
                title: Self.breakTitle(isLong: isLong),
                start: cursor,
                end: breakEnd,
                taskID: task.id,
                isDone: task.isDone
            ))
            cursor = breakEnd
        }

        // Meetings are immovable: drop them in and sort the whole day.
        for meeting in meetings {
            blocks.append(ScheduledBlock(
                id: blockID(for: meeting),
                kind: .meeting,
                title: meeting.title,
                start: meeting.start,
                end: meeting.end,
                taskID: nil,
                isDone: false,
                calendarName: meeting.calendarName,
                notes: meeting.notes,
                isAllDay: meeting.isAllDay
            ))
        }

        return blocks.sorted { lhs, rhs in
            if lhs.start == rhs.start { return lhs.id < rhs.id }
            return lhs.start < rhs.start
        }
    }

    /// One work block's worth of a task.
    struct Chunk {
        let task: DayTask
        /// Counts on from the blocks already finished, so ids stay unique.
        let number: Int
        let minutes: Int
    }

    /// Splits what's left of a task into work blocks of at most
    /// `workMinutes`, capped at `maxTaskMinutes` in all.
    static func chunks(of task: DayTask, settings: Settings, firstMinutes: Int? = nil) -> [Chunk] {
        var remaining = min(task.remainingMinutes, Self.maxTaskMinutes)
        var number = max(0, task.completedBlocks)
        var chunks: [Chunk] = []
        if let firstMinutes, remaining > 0 {
            let minutes = min(max(1, firstMinutes), Self.maxTaskMinutes)
            number += 1
            chunks.append(Chunk(task: task, number: number, minutes: minutes))
            remaining = max(0, remaining - minutes)
        }
        while remaining > 0 {
            let minutes = min(settings.workMinutes, remaining)
            number += 1
            chunks.append(Chunk(task: task, number: number, minutes: minutes))
            remaining -= minutes
        }
        return chunks
    }

    /// Advances `start` until a block of `minutes` no longer overlaps any
    /// meeting. Each collision jumps the cursor to that meeting's end, so the
    /// loop always terminates (the cursor strictly increases).
    static func firstFreeSlot(
        from start: Date,
        minutes: Int,
        meetings: [Meeting],
        calendar: Calendar
    ) -> Date {
        var cursor = start
        var didMove = true

        while didMove {
            didMove = false
            let end = adding(minutes: minutes, to: cursor, calendar: calendar)

            for meeting in meetings where cursor < meeting.end && end > meeting.start {
                cursor = meeting.end
                didMove = true
                break
            }
        }
        return cursor
    }

    static func adding(minutes: Int, to date: Date, calendar: Calendar) -> Date {
        calendar.date(byAdding: .minute, value: minutes, to: date) ?? date
    }
}
