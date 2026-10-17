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

private func describe(_ blocks: [ScheduledBlock]) -> [String] {
    blocks.map { "\($0.kind.rawValue) \(fmt($0.start))-\(fmt($0.end))" }
}

private func task(_ title: String, _ minutes: Int, done: Bool = false) -> DayTask {
    DayTask(title: title, estimateMinutes: minutes, completedAt: done ? at(8) : nil)
}

private let settings = Scheduler.Settings(
    workMinutes: 25, shortBreakMinutes: 5, longBreakMinutes: 15, pomodorosBeforeLongBreak: 4
)

final class SchedulerTests: XCTestCase {

    // MARK: - Pomodoro chunking

    func testShortTaskIsOnePomodoro() {
        let blocks = Scheduler.buildDay(
            tasks: [task("Email", 20)],
            meetings: [],
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        XCTAssertEqual(describe(blocks), ["work 09:00-09:20", "shortBreak 09:20-09:25"])
    }

    func testLongTaskSplitsIntoPomodorosWithBreaks() {
        let blocks = Scheduler.buildDay(
            tasks: [task("Deep work", 30)],
            meetings: [],
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        XCTAssertEqual(describe(blocks), [
            "work 09:00-09:25",      // first 25 of 30
            "shortBreak 09:25-09:30",
            "work 09:30-09:35",      // remaining 5
            "shortBreak 09:35-09:40",
        ])
    }

    func testLongBreakAfterFourthPomodoro() {
        let blocks = Scheduler.buildDay(
            tasks: [task("Marathon", 100)],
            meetings: [],
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        let breaks = blocks.filter(\.isBreak)
        XCTAssertEqual(breaks.count, 4)
        XCTAssertEqual(breaks[0].kind, .shortBreak)
        XCTAssertEqual(breaks[1].kind, .shortBreak)
        XCTAssertEqual(breaks[2].kind, .shortBreak)
        XCTAssertEqual(breaks[3].kind, .longBreak, "4th break should be the long one")
        XCTAssertEqual(breaks[3].minutes, 15)
    }

    func testSecondTaskStartsAfterFirstTasksBreak() {
        let blocks = Scheduler.buildDay(
            tasks: [task("A", 25), task("B", 25)],
            meetings: [],
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        let work = blocks.filter { $0.kind == .work }
        XCTAssertEqual(fmt(work[0].start), "09:00")
        XCTAssertEqual(fmt(work[1].start), "09:30", "B starts after A's break")
    }

    // MARK: - Meeting conflicts

    func testWorkBlockIsPushedPastOverlappingMeeting() {
        let standup = Meeting(id: "m1", title: "Standup", start: at(9, 10), end: at(9, 30))
        let blocks = Scheduler.buildDay(
            tasks: [task("Deep work", 30)],
            meetings: [standup],
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        XCTAssertEqual(describe(blocks), [
            "meeting 09:10-09:30",
            "work 09:30-09:55",      // pushed from 09:00
            "shortBreak 09:55-10:00",
            "work 10:00-10:05",
            "shortBreak 10:05-10:10",
        ])
    }

    func testBreakIsPushedPastMeetingItWouldHaveOverlapped() {
        let meeting = Meeting(id: "m1", title: "Sync", start: at(9, 26), end: at(9, 35))
        let blocks = Scheduler.buildDay(
            tasks: [task("Deep work", 25)],
            meetings: [meeting],
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        // Work fits before the meeting; the break must jump over it.
        XCTAssertEqual(describe(blocks), [
            "work 09:00-09:25",
            "meeting 09:26-09:35",
            "shortBreak 09:35-09:40",
        ])
    }

    func testBackToBackMeetingsAreBothCleared() {
        let meetings = [
            Meeting(id: "m1", title: "One", start: at(9, 5), end: at(9, 15)),
            Meeting(id: "m2", title: "Two", start: at(9, 15), end: at(9, 45)),
        ]
        let blocks = Scheduler.buildDay(
            tasks: [task("Deep work", 25)],
            meetings: meetings,
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        let work = blocks.filter { $0.kind == .work }
        XCTAssertEqual(fmt(work[0].start), "09:45", "must clear both meetings")
    }

    func testTaskFittingEntirelyBeforeMeetingIsNotMoved() {
        let meeting = Meeting(id: "m1", title: "Later", start: at(10), end: at(11))
        let blocks = Scheduler.buildDay(
            tasks: [task("Quick", 25)],
            meetings: [meeting],
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        let work = blocks.filter { $0.kind == .work }
        XCTAssertEqual(fmt(work[0].start), "09:00", "no conflict, so no push")
    }

    // MARK: - Ordering and integrity

    func testBlocksAreSortedByStartTime() {
        let meetings = [Meeting(id: "m1", title: "Early", start: at(8, 30), end: at(8, 45))]
        let blocks = Scheduler.buildDay(
            tasks: [task("A", 50)],
            meetings: meetings,
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        let starts = blocks.map(\.start)
        XCTAssertEqual(starts, starts.sorted())
    }

    func testWorkBlocksNeverOverlapMeetings() {
        // A deliberately messy day.
        let meetings = [
            Meeting(id: "m1", title: "A", start: at(9, 20), end: at(9, 50)),
            Meeting(id: "m2", title: "B", start: at(10, 10), end: at(10, 25)),
            Meeting(id: "m3", title: "C", start: at(11, 0), end: at(12, 30)),
        ]
        let blocks = Scheduler.buildDay(
            tasks: [task("Big", 180)],
            meetings: meetings,
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        let generated = blocks.filter { !$0.isMeeting }
        for block in generated {
            for meeting in meetings {
                let overlaps = block.start < meeting.end && block.end > meeting.start
                XCTAssertFalse(
                    overlaps,
                    "\(block.kind.rawValue) \(fmt(block.start))-\(fmt(block.end)) "
                    + "overlaps meeting \(meeting.title) \(fmt(meeting.start))-\(fmt(meeting.end))"
                )
            }
        }
    }

    func testAllDayEventsDoNotBlockAnything() {
        let allDay = Meeting(id: "m1", title: "Holiday", start: at(0), end: at(23, 59), isAllDay: true)
        let blocks = Scheduler.buildDay(
            tasks: [task("Work", 25)],
            meetings: [allDay],
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        let work = blocks.filter { $0.kind == .work }
        XCTAssertEqual(fmt(work[0].start), "09:00")
    }

    /// The scheduler itself keeps completed tasks in the layout so the pure
    /// function stays predictable. The app filters them out before calling,
    /// because their slots are in the past and holding them open pushes live
    /// work further down the list.
    func testCompletedTaskStillOccupiesItsSlot() {
        let blocks = Scheduler.buildDay(
            tasks: [task("Done", 25, done: true), task("Next", 25)],
            meetings: [],
            dayStart: at(9),
            settings: settings,
            calendar: utc
        )
        let work = blocks.filter { $0.kind == .work }
        XCTAssertEqual(work.count, 2)
        XCTAssertTrue(work[0].isDone)
        XCTAssertFalse(work[1].isDone)
        XCTAssertEqual(fmt(work[1].start), "09:30", "next task unaffected by a finished one")
    }

    func testEmptyDayProducesNothing() {
        let blocks = Scheduler.buildDay(
            tasks: [], meetings: [], dayStart: at(9), settings: settings, calendar: utc
        )
        XCTAssertTrue(blocks.isEmpty)
    }

    func testTotalWorkMinutesMatchesEstimates() {
        let tasks = [task("A", 30), task("B", 50), task("C", 10)]
        let blocks = Scheduler.buildDay(
            tasks: tasks, meetings: [], dayStart: at(9), settings: settings, calendar: utc
        )
        let workMinutes = blocks.filter { $0.kind == .work }.reduce(0) { $0 + $1.minutes }
        XCTAssertEqual(workMinutes, 90, "30 + 50 + 10 of work must be scheduled")
    }

    /// The row UI renders `title` and `calendarName` straight off the block, so
    /// both have to survive the trip through the scheduler.
    func testMeetingBlockCarriesTitleAndCalendarName() {
        let meeting = Meeting(
            id: "m1", title: "Standup", start: at(10), end: at(11), calendarName: "Work"
        )
        let blocks = Scheduler.buildDay(
            tasks: [], meetings: [meeting], dayStart: at(9), settings: settings, calendar: utc
        )

        XCTAssertEqual(blocks.count, 1)
        let block = blocks[0]
        XCTAssertEqual(block.kind, .meeting)
        XCTAssertEqual(block.title, "Standup", "meeting name must reach the row")
        XCTAssertEqual(block.calendarName, "Work", "calendar name must reach the row")
        XCTAssertNil(block.taskID)
        XCTAssertTrue(block.isMeeting)
    }

    /// A meeting with no calendar attached must still carry its name.
    func testMeetingWithNilCalendarNameStillHasTitle() {
        let meeting = Meeting(id: "m1", title: "1:1", start: at(10), end: at(10, 30))
        let blocks = Scheduler.buildDay(
            tasks: [], meetings: [meeting], dayStart: at(9), settings: settings, calendar: utc
        )
        XCTAssertEqual(blocks[0].title, "1:1")
        XCTAssertNil(blocks[0].calendarName)
    }

    /// The event's description field must survive into the row, which renders it
    /// on its own line beneath the title.
    func testMeetingNotesReachTheBlock() {
        let meeting = Meeting(
            id: "m1", title: "Standup", start: at(10), end: at(10, 30),
            calendarName: "Work", notes: "Agenda: roadmap, hiring"
        )
        let blocks = Scheduler.buildDay(
            tasks: [], meetings: [meeting], dayStart: at(9), settings: settings, calendar: utc
        )
        XCTAssertEqual(blocks[0].notes, "Agenda: roadmap, hiring")
    }

    /// An event without a description must carry nil, not an empty string, so
    /// the row knows to skip the second line entirely.
    func testMeetingWithoutNotesCarriesNil() {
        let meeting = Meeting(id: "m1", title: "Standup", start: at(10), end: at(10, 30))
        let blocks = Scheduler.buildDay(
            tasks: [], meetings: [meeting], dayStart: at(9), settings: settings, calendar: utc
        )
        XCTAssertNil(blocks[0].notes)
    }

    // MARK: - All-day events

    /// An all-day event must be flagged, so the row can say "All day" instead of
    /// rendering the nonsense range "00:00–00:00".
    func testAllDayEventIsFlaggedAllDay() {
        let holiday = Meeting(
            id: "m1", title: "Holiday", start: at(0), end: at(0).addingTimeInterval(86_400),
            isAllDay: true
        )
        let blocks = Scheduler.buildDay(
            tasks: [], meetings: [holiday], dayStart: at(9), settings: settings, calendar: utc
        )
        XCTAssertEqual(blocks.count, 1)
        XCTAssertTrue(blocks[0].isAllDay)
        XCTAssertEqual(blocks[0].minutes, 1440, "spans a full day")
    }

    /// An all-day event must not offer a countdown — starting one would set a
    /// ~24 hour timer.
    func testAllDayEventIsNotFocusable() {
        let holiday = Meeting(
            id: "m1", title: "Holiday", start: at(0), end: at(0).addingTimeInterval(86_400),
            isAllDay: true
        )
        let blocks = Scheduler.buildDay(
            tasks: [], meetings: [holiday], dayStart: at(9), settings: settings, calendar: utc
        )
        XCTAssertFalse(blocks[0].isFocus, "all-day events must not be startable")
    }

    /// A timed meeting is still startable.
    func testTimedMeetingIsFocusable() {
        let standup = Meeting(id: "m1", title: "Standup", start: at(10), end: at(10, 30))
        let blocks = Scheduler.buildDay(
            tasks: [], meetings: [standup], dayStart: at(9), settings: settings, calendar: utc
        )
        XCTAssertTrue(blocks[0].isFocus)
        XCTAssertFalse(blocks[0].isAllDay)
    }

    // MARK: - Bounds

    /// Even if an absurd estimate reaches the scheduler, it must not generate
    /// thousands of blocks. 100000 minutes at 25 per chunk would be ~8000 rows.
    func testAbsurdEstimateIsClamped() {
        let blocks = Scheduler.buildDay(
            tasks: [task("Typo", 100_000)], meetings: [], dayStart: at(9),
            settings: settings, calendar: utc
        )
        let workMinutes = blocks.filter { $0.kind == .work }.reduce(0) { $0 + $1.minutes }
        XCTAssertEqual(workMinutes, Scheduler.maxTaskMinutes)
        XCTAssertLessThan(blocks.count, 60, "block count must stay bounded")
    }

    /// The clamp must not disturb ordinary values.
    func testNormalEstimateIsUntouched() {
        let blocks = Scheduler.buildDay(
            tasks: [task("Normal", 90)], meetings: [], dayStart: at(9),
            settings: settings, calendar: utc
        )
        let workMinutes = blocks.filter { $0.kind == .work }.reduce(0) { $0 + $1.minutes }
        XCTAssertEqual(workMinutes, 90)
    }
}
