import XCTest
@testable import PomodoroCore

/// Fixed calendar so the layout is deterministic regardless of the machine's
/// timezone or the day the tests happen to run.
private var utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func at(_ hour: Int, _ minute: Int = 0) -> Date {
    var components = DateComponents()
    components.year = 2026
    components.month = 10
    components.day = 14
    components.hour = hour
    components.minute = minute
    return utc.date(from: components)!
}

private func fmt(_ date: Date) -> String {
    let parts = utc.dateComponents([.hour, .minute], from: date)
    return String(format: "%02d:%02d", parts.hour ?? 0, parts.minute ?? 0)
}

/// "title kind start-end", breaks without a title so the rows read cleanly.
private func describe(_ blocks: [ScheduledBlock]) -> [String] {
    blocks.map { block in
        let range = "\(fmt(block.start))-\(fmt(block.end))"
        return block.kind == .work ? "\(block.title) \(range)" : "\(block.kind.rawValue) \(range)"
    }
}

private let settings = Scheduler.Settings(
    workMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, pomodorosBeforeLongBreak: 4
)

final class PriorityTests: XCTestCase {

    // MARK: - Priority order

    func testMoreUrgentTaskIsPlannedFirst() {
        let later = DayTask(title: "Later", estimateMinutes: 25, priority: .leastUrgent)
        let urgent = DayTask(title: "Urgent", estimateMinutes: 25, priority: .urgent)
        let blocks = Scheduler.buildDay(
            tasks: [later, urgent], meetings: [], dayStart: at(9), settings: settings, calendar: utc
        )
        XCTAssertEqual(describe(blocks), [
            "Urgent 09:00-09:25", "shortBreak 09:25-09:30",
            "Later 09:30-09:55", "shortBreak 09:55-10:00",
        ])
    }

    func testAllThreeLevelsSortAndTiesKeepTheOrderAdded() {
        let tasks = [
            DayTask(title: "Y1", estimateMinutes: 5, priority: .leastUrgent),
            DayTask(title: "O1", estimateMinutes: 5, priority: .lessUrgent),
            DayTask(title: "R1", estimateMinutes: 5, priority: .urgent),
            DayTask(title: "O2", estimateMinutes: 5, priority: .lessUrgent),
            DayTask(title: "Y2", estimateMinutes: 5, priority: .leastUrgent),
            DayTask(title: "R2", estimateMinutes: 5, priority: .urgent),
        ]
        XCTAssertEqual(Scheduler.ordered(tasks).map(\.title), ["R1", "R2", "O1", "O2", "Y1", "Y2"])
    }

    /// An urgent task added while another is being worked on waits for that
    /// block to end, then goes ahead of the rest of it.
    func testTaskBeingWorkedOnKeepsItsBlockThenUrgentGoesNext() {
        let current = DayTask(title: "Current", estimateMinutes: 50, priority: .leastUrgent)
        let urgent = DayTask(title: "Urgent", estimateMinutes: 25, priority: .urgent)
        let blocks = Scheduler.buildDay(
            tasks: [current, urgent], meetings: [], dayStart: at(9), settings: settings,
            firstTaskID: current.id, calendar: utc
        )
        XCTAssertEqual(describe(blocks), [
            "Current 09:00-09:25", "shortBreak 09:25-09:30",
            "Urgent 09:30-09:55", "shortBreak 09:55-10:00",
            "Current 10:00-10:25", "shortBreak 10:25-10:30",
        ])
        // The block under way keeps its id, so the countdown stays attached.
        XCTAssertEqual(blocks.first?.id, "\(current.id.uuidString)-work-1")
        XCTAssertEqual(blocks[4].id, "\(current.id.uuidString)-work-2")
    }

    func testBlockUnderWayIsNotMovedByAMeeting() {
        let current = DayTask(title: "Current", estimateMinutes: 25)
        let meeting = Meeting(id: "m", title: "Standup", start: at(9, 10), end: at(9, 20))
        let blocks = Scheduler.buildDay(
            tasks: [current], meetings: [meeting], dayStart: at(9), settings: settings,
            firstTaskID: current.id, calendar: utc
        )
        XCTAssertEqual(blocks.first { $0.kind == .work }.map { fmt($0.start) }, "09:00")
    }

    // MARK: - Progress

    /// The bug: a 50 minute task that had finished its first block was laid
    /// out as 50 minutes again.
    func testFinishedBlocksAreNotPlannedAgain() {
        let task = DayTask(title: "Report", estimateMinutes: 50, completedMinutes: 25, completedBlocks: 1)
        let blocks = Scheduler.buildDay(
            tasks: [task], meetings: [], dayStart: at(10), settings: settings, calendar: utc
        )
        XCTAssertEqual(describe(blocks), ["Report 10:00-10:25", "shortBreak 10:25-10:30"])
        XCTAssertEqual(blocks.first?.id, "\(task.id.uuidString)-work-2")
    }

    func testRemainingMinutesNeverGoesNegative() {
        XCTAssertEqual(DayTask(estimateMinutes: 30, completedMinutes: 25).remainingMinutes, 5)
        XCTAssertEqual(DayTask(estimateMinutes: 20, completedMinutes: 25).remainingMinutes, 0)
    }

    // MARK: - Breaks after a finished block

    func testOwedBreakGoesFirstAndWorkFollowsIt() {
        let task = DayTask(title: "Next", estimateMinutes: 25)
        let owed = Scheduler.PendingBreak(start: at(9, 25), isLong: false, id: "break-1")
        let blocks = Scheduler.buildDay(
            tasks: [task], meetings: [], dayStart: at(9, 27), settings: settings,
            pendingBreak: owed, calendar: utc
        )
        XCTAssertEqual(describe(blocks), [
            "shortBreak 09:25-09:30", "Next 09:30-09:55", "shortBreak 09:55-10:00",
        ])
        XCTAssertEqual(blocks.first?.id, "break-1")
    }

    func testLongBreakCountsBlocksFinishedEarlierToday() {
        let task = DayTask(title: "Fourth", estimateMinutes: 25)
        let blocks = Scheduler.buildDay(
            tasks: [task], meetings: [], dayStart: at(11), settings: settings,
            completedPomodoros: 3, calendar: utc
        )
        XCTAssertEqual(describe(blocks), ["Fourth 11:00-11:25", "longBreak 11:25-11:40"])
    }

    // MARK: - Saved history

    /// History saved before priorities existed must still load; otherwise
    /// every saved day would be unreadable after the update.
    func testTaskSavedBeforePrioritiesStillDecodes() throws {
        let json = """
        {"2026-10-15":[{"id":"11111111-2222-3333-4444-555555555555","title":"Old task",\
        "shortLabel":"","estimateMinutes":50,"completedAt":782000000}]}
        """
        let history = try JSONDecoder().decode([String: [DayTask]].self, from: Data(json.utf8))
        let task = try XCTUnwrap(history["2026-10-15"]?.first)
        XCTAssertEqual(task.title, "Old task")
        XCTAssertEqual(task.estimateMinutes, 50)
        XCTAssertTrue(task.isDone)
        XCTAssertEqual(task.priority, .leastUrgent)
        XCTAssertEqual(task.completedMinutes, 0)
        XCTAssertEqual(task.completedBlocks, 0)
    }

    func testNewFieldsSurviveSaving() throws {
        let task = DayTask(title: "T", estimateMinutes: 50, priority: .urgent,
                           completedMinutes: 25, completedBlocks: 1)
        let decoded = try JSONDecoder().decode(DayTask.self, from: JSONEncoder().encode(task))
        XCTAssertEqual(decoded, task)
    }
}
