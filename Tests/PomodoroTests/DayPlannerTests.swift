import XCTest
import PomodoroCore
@testable import Pomodoro

/// No real preferences, calendars, timers, permission prompts or sounds.
private final class MemoryDefaults: UserDefaults {
    private var values: [String: Any] = [:]
    init() { super.init(suiteName: "PomodoroTests.\(UUID())")! }
    override func object(forKey key: String) -> Any? { values[key] }
    override func set(_ value: Any?, forKey key: String) { values[key] = value }
    override func removeObject(forKey key: String) { values.removeValue(forKey: key) }
    override func string(forKey key: String) -> String? { values[key] as? String }
    override func bool(forKey key: String) -> Bool { values[key] as? Bool ?? false }
    override func integer(forKey key: String) -> Int { values[key] as? Int ?? 0 }
    override func double(forKey key: String) -> Double { values[key] as? Double ?? 0 }
    override func stringArray(forKey key: String) -> [String]? { values[key] as? [String] }
}

@MainActor
private final class CalendarStub: PlannerCalendar {
    var isAuthorized = false
    var statusDescription: String { isAuthorized ? "Connected" : "Not connected" }
    var lastError: String?
    var events: [Meeting] = []
    func requestAccess() async {}
    func eventCalendars() -> [CalendarService.CalendarInfo] { [] }
    func meetings(on day: Date, excluding excluded: Set<String>) -> [Meeting] {
        isAuthorized ? events : []
    }
}

@MainActor
private final class Fixture {
    let defaults = MemoryDefaults()
    let calendar = CalendarStub()
    var now = Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: 16, hour: 12))!
    var sounds = 0
    func planner() -> DayPlanner {
        DayPlanner(defaults: defaults, calendar: calendar, now: { self.now },
                   automaticallyUpdates: false, playCompletion: { self.sounds += 1 })
    }
    func advance(_ minutes: Int) { now = now.addingTimeInterval(Double(minutes * 60)) }
    func savedHistory() throws -> [String: [DayTask]] {
        let data = Data(defaults.string(forKey: "dayHistory")!.utf8)
        return try JSONDecoder().decode([String: [DayTask]].self, from: data)
    }
    func addMeeting(allDay: Bool = false) {
        calendar.isAuthorized = true
        let start = allDay ? Calendar.current.startOfDay(for: now) : now
        calendar.events = [Meeting(id: "private-event-id", title: "Private meeting title",
            start: start, end: start.addingTimeInterval(allDay ? 86400 : 1800),
            isAllDay: allDay, calendarName: "Private calendar", notes: "Private meeting notes")]
    }
}

final class DayPlannerTests: XCTestCase {
    @MainActor func testChangingDurationDoesNotCreditUnworkedMinutes() async {
        let f = Fixture(), p = f.planner()
        p.addTask(title: "Fifty minutes", minutes: 50)
        p.toggleRunPause()
        let originalEnd = p.activeBlock!.end
        f.advance(5)
        p.workMinutes = 50
        p.refreshCalendar(force: true)
        XCTAssertEqual(p.activeBlock?.minutes, 25)
        XCTAssertEqual(p.activeBlock?.end, originalEnd)
        f.advance(20)
        p.tick()
        XCTAssertEqual(p.tasks[0].completedMinutes, 25)
        XCTAssertFalse(p.tasks[0].isDone)
        XCTAssertEqual(f.sounds, 1)
    }

    @MainActor func testFrozenDurationSurvivesPauseResumeAndBothKindsOfRelaunch() async {
        let f = Fixture(), p = f.planner()
        p.addTask(title: "Long task", minutes: 100)
        p.toggleRunPause()
        f.advance(5)
        p.pause()
        p.workMinutes = 50
        let paused = f.planner()
        XCTAssertFalse(paused.isRunning)
        XCTAssertEqual(paused.remaining, 20 * 60)
        XCTAssertEqual(paused.activeBlock?.minutes, 25)
        f.advance(10)
        paused.toggleRunPause()
        let running = f.planner()
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.activeBlock?.end, f.now.addingTimeInterval(20 * 60))
        running.workMinutes = 10
        XCTAssertEqual(running.activeBlock?.minutes, 25)
        f.advance(20)
        running.tick()
        XCTAssertEqual(running.tasks[0].completedMinutes, 25)
        XCTAssertEqual(running.blocks.first { $0.kind == .work }?.minutes, 10)
    }

    @MainActor func testExpiredSavedWorkIsCreditedOnceUsingOriginalDuration() async {
        let f = Fixture(), p = f.planner()
        p.addTask(title: "Long task", minutes: 100)
        p.toggleRunPause()
        p.workMinutes = 50
        f.advance(30)
        let recovered = f.planner()
        XCTAssertEqual(recovered.tasks[0].completedMinutes, 25)
        XCTAssertFalse(recovered.isRunning)
        XCTAssertEqual(f.planner().tasks[0].completedMinutes, 25)
    }

    @MainActor func testOvernightRelaunchCreditsFinishedWorkToItsOwningDay() async throws {
        let f = Fixture()
        f.advance(11 * 60 + 30)
        let p = f.planner()
        p.addTask(title: "Yesterday", minutes: 25)
        p.toggleRunPause()
        let expectedEnd = f.now.addingTimeInterval(25 * 60)
        f.advance(40)

        let recovered = f.planner()
        XCTAssertTrue(recovered.tasks.isEmpty)
        XCTAssertFalse(recovered.isRunning)
        XCTAssertNil(f.defaults.string(forKey: "activeBlockID"))
        let yesterday = try XCTUnwrap(f.savedHistory()["2026-10-16"]?.first)
        XCTAssertEqual(yesterday.completedMinutes, 25)
        XCTAssertEqual(yesterday.completedBlocks, 1)
        XCTAssertEqual(yesterday.completedAt, expectedEnd)
        XCTAssertFalse(recovered.blocks.contains { $0.isBreak })
        XCTAssertEqual(f.sounds, 0, "Recovery should not play an old completion sound")

        recovered.addTask(title: "Today", minutes: 25)
        recovered.toggleRunPause()
        f.advance(25); recovered.tick()
        XCTAssertEqual(f.defaults.integer(forKey: "completedPomodoros"), 1)
        XCTAssertEqual(f.defaults.string(forKey: "completedPomodorosDay"), "2026-10-17")
        XCTAssertEqual(recovered.blocks.first?.kind, .shortBreak)
    }

    @MainActor func testOvernightRecoveryUsesFrozenDurationAndCannotCreditTheSameBlockTwice() async throws {
        let f = Fixture()
        f.advance(11 * 60 + 30)
        let p = f.planner()
        p.addTask(title: "Long task", minutes: 100)
        p.toggleRunPause()
        let savedID = p.activeBlockID
        let savedEnd = f.defaults.object(forKey: "endDate")
        p.workMinutes = 50
        f.advance(40)
        let today = DayTask(title: "Already saved for today", estimateMinutes: 50)
        var history = try f.savedHistory()
        history["2026-10-17"] = [today]
        f.defaults.set(String(decoding: try JSONEncoder().encode(history), as: UTF8.self), forKey: "dayHistory")

        let recovered = f.planner()
        XCTAssertEqual(recovered.tasks, [today])
        var yesterday = try XCTUnwrap(f.savedHistory()["2026-10-16"]?.first)
        XCTAssertEqual(yesterday.completedMinutes, 25)
        XCTAssertEqual(yesterday.completedBlocks, 1)
        XCTAssertFalse(yesterday.isDone)

        // Simulate exit after history was saved but before timer state cleared.
        f.defaults.set(savedID, forKey: "activeBlockID")
        f.defaults.set(savedEnd, forKey: "endDate")
        f.defaults.set(true, forKey: "isRunning")
        f.defaults.set(25.0 * 60, forKey: "activeDuration")
        _ = f.planner()
        yesterday = try XCTUnwrap(f.savedHistory()["2026-10-16"]?.first)
        XCTAssertEqual(yesterday.completedMinutes, 25)
        XCTAssertEqual(yesterday.completedBlocks, 1)
        XCTAssertEqual(try f.savedHistory()["2026-10-17"], [today])
    }

    @MainActor func testOvernightRecoveryDoesNotCreditPausedWork() async throws {
        let f = Fixture()
        f.advance(11 * 60 + 30)
        let p = f.planner()
        p.addTask(title: "Paused yesterday", minutes: 25)
        p.toggleRunPause()
        f.advance(5); p.pause()
        f.advance(35)

        let recovered = f.planner()
        let yesterday = try XCTUnwrap(f.savedHistory()["2026-10-16"]?.first)
        XCTAssertEqual(yesterday.completedMinutes, 0)
        XCTAssertFalse(yesterday.isDone)
        XCTAssertTrue(recovered.tasks.isEmpty)
        XCTAssertNil(recovered.activeBlockID)
    }

    @MainActor func testOvernightRecoveryDoesNotCreditUnexpiredWork() async throws {
        let f = Fixture()
        f.advance(11 * 60 + 50)
        let p = f.planner()
        p.addTask(title: "Unfinished yesterday", minutes: 25)
        p.toggleRunPause()
        f.advance(15)

        let recovered = f.planner()
        let yesterday = try XCTUnwrap(f.savedHistory()["2026-10-16"]?.first)
        XCTAssertEqual(yesterday.completedMinutes, 0)
        XCTAssertFalse(yesterday.isDone)
        XCTAssertTrue(recovered.tasks.isEmpty)
        XCTAssertNil(recovered.activeBlockID)
    }

    @MainActor func testOlderSavedCountdownWithoutDurationStillRestores() async {
        let f = Fixture(), p = f.planner()
        p.addTask(title: "Older save", minutes: 50)
        p.toggleRunPause()
        f.defaults.removeObject(forKey: "activeDuration")
        f.advance(5)
        let recovered = f.planner()
        XCTAssertTrue(recovered.isRunning)
        XCTAssertEqual(recovered.remaining, 20 * 60)
        XCTAssertEqual(recovered.activeBlock?.minutes, 25)
    }

    @MainActor func testIdleStartReplansWorkInsteadOfSelectingItsOldBreakOrNothing() async {
        for delay in [26, 31] {
            let f = Fixture(), p = f.planner()
            p.addTask(title: "Unstarted", minutes: 25)
            f.advance(delay)
            // No panel/calendar refresh: Start itself must handle stale slots.
            p.toggleRunPause()
            XCTAssertTrue(p.isRunning)
            XCTAssertEqual(p.activeBlock?.kind, .work)
            XCTAssertEqual(p.activeBlock?.start, f.now)
            XCTAssertEqual(p.remaining, 25 * 60)
        }
    }

    @MainActor func testAllDayEventsRemainVisibleButNeverStartOrInterruptChaining() async {
        let f = Fixture()
        f.addMeeting(allDay: true)
        let p = f.planner()
        p.refreshCalendar(force: true)
        let eventID = p.blocks.first!.id
        p.toggleRunPause()
        XCTAssertNil(p.activeBlockID)
        p.startBlock(eventID)
        XCTAssertNil(p.activeBlockID)
        p.addTask(title: "Real work", minutes: 50)
        p.autoStartNext = true
        p.toggleRunPause()
        XCTAssertEqual(p.activeBlock?.kind, .work)
        p.startBlock(eventID)
        XCTAssertEqual(p.activeBlock?.kind, .work)
        XCTAssertTrue(p.blocks.contains { $0.isAllDay })
        f.advance(25); p.tick()
        XCTAssertEqual(p.activeBlock?.kind, .shortBreak)
        XCTAssertTrue(p.isRunning)
        f.advance(5); p.tick()
        XCTAssertEqual(p.activeBlock?.kind, .work)
        XCTAssertTrue(p.isRunning)
    }

    @MainActor func testStartedBreakKeepsDurationAcrossSettingsAndRelaunch() async {
        let f = Fixture(), p = f.planner()
        p.addTask(title: "Work", minutes: 50)
        p.autoStartNext = true
        p.toggleRunPause()
        f.advance(25); p.tick()
        f.advance(1); p.pause()
        p.shortBreakMinutes = 10
        let recovered = f.planner()
        XCTAssertEqual(recovered.activeBlock?.kind, .shortBreak)
        XCTAssertEqual(recovered.activeBlock?.minutes, 5)
        XCTAssertEqual(recovered.remaining, 4 * 60)
        recovered.toggleRunPause()
        f.advance(4); recovered.tick()
        XCTAssertEqual(recovered.activeBlock?.kind, .work)
    }

    @MainActor func testClearAllPersistsRemovalOfOwedAndRunningBreaks() async {
        for autoStart in [false, true] {
            let f = Fixture(), p = f.planner()
            p.addTask(title: "Work", minutes: 25)
            p.autoStartNext = autoStart
            p.toggleRunPause()
            f.advance(25); p.tick()
            XCTAssertNotNil(f.defaults.object(forKey: "pendingBreakEarnedAt"))
            f.advance(1)
            p.clearAll()

            XCTAssertNil(f.defaults.object(forKey: "pendingBreakEarnedAt"))
            XCTAssertNil(f.defaults.object(forKey: "pendingBreakIsLong"))
            let recovered = f.planner()
            XCTAssertTrue(recovered.tasks.isEmpty)
            XCTAssertTrue(recovered.blocks.isEmpty)
            XCTAssertNil(recovered.activeBlockID)
            XCTAssertFalse(recovered.isRunning)
        }
    }

    @MainActor func testStartingAnOngoingMeetingCountsDownToItsFixedEnd() async {
        let f = Fixture()
        f.addMeeting()
        let p = f.planner()
        p.refreshCalendar(force: true)
        f.advance(10)
        p.toggleRunPause()
        XCTAssertEqual(p.remaining, 20 * 60)
        XCTAssertEqual(f.defaults.object(forKey: "endDate") as? Date, f.calendar.events[0].end)
        f.advance(19); p.tick()
        XCTAssertEqual(p.remaining, 60)
        f.advance(1); p.tick()
        XCTAssertFalse(p.isRunning)
        XCTAssertNil(p.activeBlockID)
        XCTAssertEqual(f.sounds, 1)
    }

    @MainActor func testMeetingPauseResumeResetAndRelaunchKeepItsFixedEnd() async {
        let f = Fixture()
        f.addMeeting()
        let p = f.planner()
        p.refreshCalendar(force: true)
        f.advance(10); p.toggleRunPause()
        f.advance(2); p.pause()
        f.advance(3)
        let recovered = f.planner()
        recovered.refreshCalendar(force: true)
        XCTAssertFalse(recovered.isRunning)
        XCTAssertEqual(recovered.remaining, 15 * 60)
        f.advance(1); recovered.toggleRunPause()
        XCTAssertEqual(recovered.remaining, 14 * 60)
        XCTAssertEqual(f.defaults.object(forKey: "endDate") as? Date, f.calendar.events[0].end)
        f.advance(1); recovered.resetActive()
        XCTAssertFalse(recovered.isRunning)
        XCTAssertEqual(recovered.remaining, 13 * 60)
        f.advance(1); recovered.toggleRunPause()
        XCTAssertEqual(recovered.remaining, 12 * 60)
        let running = f.planner()
        running.refreshCalendar(force: true)
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.remaining, 12 * 60)
        f.advance(12); running.tick()
        XCTAssertFalse(running.isRunning)
    }

    @MainActor func testMeetingRestorationCorrectsAnOldTimerEndAndDropsExpiredEvents() async {
        for elapsed in [10, 35] {
            let f = Fixture()
            f.addMeeting()
            let p = f.planner()
            p.refreshCalendar(force: true)
            p.toggleRunPause()
            f.defaults.set(f.now.addingTimeInterval(60 * 60), forKey: "endDate")
            f.advance(elapsed)
            let recovered = f.planner()
            recovered.refreshCalendar(force: true)
            XCTAssertEqual(recovered.isRunning, elapsed < 30)
            XCTAssertEqual(recovered.remaining, Double(max(0, 30 - elapsed) * 60))
            if elapsed > 30 {
                XCTAssertNil(recovered.activeBlockID)
                recovered.startBlock(Scheduler.blockID(for: f.calendar.events[0]))
                XCTAssertNil(recovered.activeBlockID)
            } else {
                XCTAssertEqual(f.defaults.object(forKey: "endDate") as? Date, f.calendar.events[0].end)
            }
        }
    }

    @MainActor func testExpiredPausedMeetingIsClearedByResumeOrReset() async {
        for reset in [false, true] {
            let f = Fixture()
            f.addMeeting()
            let p = f.planner()
            p.refreshCalendar(force: true)
            p.toggleRunPause()
            f.advance(10); p.pause()
            f.advance(25)
            if reset { p.resetActive() } else { p.toggleRunPause() }
            XCTAssertNil(p.activeBlockID)
            XCTAssertFalse(p.isRunning)
            XCTAssertEqual(p.remaining, 0)
            XCTAssertNil(f.defaults.string(forKey: "activeBlockID"))
        }
    }

    @MainActor func testCalendarRefreshUpdatesRunningMeetingDeadline() async {
        let f = Fixture()
        f.addMeeting()
        let p = f.planner()
        p.refreshCalendar(force: true)
        p.toggleRunPause()
        f.advance(10)
        let event = f.calendar.events[0]
        for remainingMinutes in [30, 5, 0] {
            f.calendar.events = [Meeting(id: event.id, title: event.title, start: event.start,
                end: f.now.addingTimeInterval(Double(remainingMinutes * 60)))]
            p.refreshCalendar(force: true)
            XCTAssertEqual(p.remaining, Double(remainingMinutes * 60))
            XCTAssertEqual(p.isRunning, remainingMinutes > 0)
        }
        XCTAssertNil(p.activeBlockID)
        XCTAssertEqual(f.sounds, 1)
    }

    @MainActor func testMeetingRestorationWaitsForCalendarForRunningAndPausedTimers() async {
        for paused in [false, true] {
            let f = Fixture()
            f.addMeeting()
            let p = f.planner()
            p.refreshCalendar(force: true)
            p.toggleRunPause()
            f.advance(5)
            if paused { p.pause() }
            let savedID = p.activeBlockID
            let recovered = f.planner()
            XCTAssertEqual(f.defaults.string(forKey: "activeBlockID"), savedID)
            recovered.refreshCalendar(force: true)
            XCTAssertEqual(recovered.activeBlockID, savedID)
            XCTAssertEqual(recovered.isRunning, !paused)
            XCTAssertEqual(recovered.remaining, 25 * 60)
        }
    }

    @MainActor func testUnavailableMeetingClearsPendingRestoration() async {
        for denied in [false, true] {
            let f = Fixture()
            f.addMeeting()
            let p = f.planner()
            p.refreshCalendar(force: true); p.toggleRunPause()
            let recovered = f.planner()
            if denied { f.calendar.isAuthorized = false } else { f.calendar.events = [] }
            recovered.refreshCalendar(force: true)
            XCTAssertNil(recovered.activeBlockID)
            XCTAssertFalse(recovered.isRunning)
            XCTAssertNil(f.defaults.string(forKey: "activeBlockID"))
        }
    }

    @MainActor func testNewWorkStartSupersedesPendingMeetingRestoration() async {
        let f = Fixture()
        f.addMeeting()
        let p = f.planner()
        p.addTask(title: "Work", minutes: 25)
        p.refreshCalendar(force: true); p.toggleRunPause()
        XCTAssertEqual(p.activeBlock?.kind, .meeting)
        let recovered = f.planner()
        recovered.toggleRunPause()
        recovered.refreshCalendar(force: true)
        XCTAssertEqual(recovered.activeBlock?.kind, .work)
        XCTAssertTrue(recovered.isRunning)
    }

    @MainActor func testObservedAuthorizationLossClearsMeetingsAndStopsMeetingTimer() async {
        let f = Fixture()
        f.addMeeting()
        let p = f.planner()
        p.addTask(title: "Work", minutes: 25)
        p.refreshCalendar(force: true); p.toggleRunPause()
        f.calendar.isAuthorized = false
        p.refreshCalendar(force: true)
        XCTAssertFalse(p.calendarAuthorized)
        XCTAssertTrue(p.meetings.isEmpty)
        XCTAssertFalse(p.blocks.contains { $0.isMeeting })
        XCTAssertFalse(p.isRunning)
        XCTAssertNil(f.defaults.string(forKey: "activeBlockID"))
        XCTAssertEqual(p.blocks.first?.start, f.now)
        p.toggleRunPause()
        p.refreshCalendar(force: true)
        XCTAssertTrue(p.isRunning, "Permission loss must not stop task timers")
    }

    @MainActor func testCalendarTextIsAbsentFromDiagnosticsInEveryDisplayState() async {
        let f = Fixture()
        f.addMeeting()
        let event = f.calendar.events[0]
        f.calendar.events = [Meeting(id: event.id, title: event.title,
            start: f.now.addingTimeInterval(5 * 60), end: f.now.addingTimeInterval(35 * 60),
            calendarName: event.calendarName, notes: event.notes)]
        f.defaults.set("old private calendar notes", forKey: "diagnostics")
        let p = f.planner()
        for running in [false, true] {
            p.refreshCalendar(force: true)
            if running { p.toggleRunPause() }
            p.refreshDiagnostics()
            let diagnostics = f.defaults.string(forKey: "diagnostics")!
            for text in [event.id, event.title, event.calendarName!, event.notes!, "old private calendar notes"] {
                XCTAssertFalse(diagnostics.contains(text), text)
            }
        }
    }
}
