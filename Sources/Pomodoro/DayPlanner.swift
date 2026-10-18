import Foundation
import AppKit
import PomodoroCore

/// Owns the day's tasks, the calendar meetings, and the derived timeline.
///
/// Nothing about the layout lives here — `Scheduler` computes it. This type is
/// responsible for persistence, timers, and the running countdown.
@MainActor
final class DayPlanner: ObservableObject {
    // MARK: - Published state

    @Published private(set) var tasks: [DayTask] = []
    @Published private(set) var meetings: [Meeting] = []
    @Published private(set) var blocks: [ScheduledBlock] = []

    @Published private(set) var activeBlockID: ScheduledBlock.ID?
    @Published private(set) var remaining: TimeInterval = 0
    @Published private(set) var isRunning = false

    @Published private(set) var calendarAuthorized = false
    @Published private(set) var calendarError: String?

    /// Set when saved history could not be read, so the UI can say so instead
    /// of silently presenting an empty day.
    @Published private(set) var historyLoadError: String?

    /// What the popover actually measured during layout. Recorded because a
    /// rendering failure can't be screenshotted from here.
    @Published private(set) var layoutReport = "not measured"

    /// Called from GeometryReaders in the view. Assigns only on change, so it
    /// can't drive a layout feedback loop.
    func recordLayout(container: CGSize, timeline: CGSize) {
        let report = String(
            format: "container %.0fx%.0f | timeline %.0fx%.0f | rows %d",
            container.width, container.height, timeline.width, timeline.height, blocks.count
        )
        guard report != layoutReport else { return }
        layoutReport = report
        // Write straight away, so simply opening the popover is enough to
        // capture the measurement.
        writeDiagnostics()
    }

    /// Bumped once a minute so time-dependent labels re-render even when idle.
    @Published private(set) var clock = Date()

    // MARK: - Settings

    @Published var showLabelInMenuBar: Bool {
        didSet { defaults.set(showLabelInMenuBar, forKey: Key.showLabel) }
    }

    @Published var workMinutes: Int {
        didSet { persistSettings(); reschedule() }
    }

    @Published var shortBreakMinutes: Int {
        didSet { persistSettings(); reschedule() }
    }

    @Published var longBreakMinutes: Int {
        didSet { persistSettings(); reschedule() }
    }

    @Published var dayStartHour: Int {
        didSet { persistSettings(); reschedule() }
    }

    @Published var dayStartMinute: Int {
        didSet { persistSettings(); reschedule() }
    }

    @Published var finishTimeEnabled: Bool {
        didSet { defaults.set(finishTimeEnabled, forKey: "finishTimeEnabled") }
    }

    @Published var finishHour: Int {
        didSet { defaults.set(finishHour, forKey: "finishHour") }
    }

    @Published var finishMinute: Int {
        didSet { defaults.set(finishMinute, forKey: "finishMinute") }
    }

    /// What Finish time starts at, and what its boxes return to when emptied.
    static let defaultFinishHour = 17
    static let defaultFinishMinute = 0

    var finishTime: Date? {
        guard finishTimeEnabled else { return nil }
        return Calendar.current.date(bySettingHour: finishHour, minute: finishMinute,
                                     second: 0, of: clock)
    }

    /// True when the panel is folded up to just the countdown box and footer.
    @Published var panelCollapsed: Bool {
        didSet { defaults.set(panelCollapsed, forKey: Key.panelCollapsed) }
    }

    /// Roll straight into the next block when one finishes, instead of waiting
    /// to be started. Off by default.
    @Published var autoStartNext: Bool {
        didSet { defaults.set(autoStartNext, forKey: Key.autoStartNext) }
    }

    /// Calendars switched off in Settings. Stored as the ones to leave out
    /// rather than the ones to use, so a calendar added later counts by default.
    @Published var excludedCalendarIDs: Set<String> {
        didSet {
            defaults.set(Array(excludedCalendarIDs), forKey: Key.excludedCalendars)
            refreshCalendar(force: true)
        }
    }

    /// Every calendar on the Mac, for the Settings list.
    var availableCalendars: [CalendarService.CalendarInfo] {
        calendar.eventCalendars()
    }

    // MARK: - Collaborators

    let calendar: any PlannerCalendar

    // MARK: - Private

    private let defaults: UserDefaults
    private let now: () -> Date
    private let automaticallyUpdates: Bool
    private let playCompletion: () -> Void
    /// Frozen when a countdown starts, independent of future schedule settings.
    private var activeDuration: TimeInterval?
    private struct SavedCountdown {
        let id: String
        let running: Bool
        let end: Date?
        let remaining: TimeInterval
        let duration: TimeInterval?
    }
    private var pendingMeetingRestore: SavedCountdown?
    private var history: [String: [DayTask]] = [:]
    private var currentDayKey = ""
    private var endDate: Date?
    private var ticker: Timer?
    private var minuteTimer: Timer?
    private var lastPublishedSecond = -1
    private var lastCalendarRefresh = Date.distantPast
    /// Work blocks run to the end today, for the long break after every fourth.
    private var completedPomodoros = 0
    /// The break owed by the last work block to run to the end: when that
    /// block ended, and whether it's the long one.
    private var pendingBreak: (earnedAt: Date, isLong: Bool)?

    private static let imminentWindow: TimeInterval = 15 * 60
    private static let calendarRefreshInterval: TimeInterval = 5 * 60
    private static let maxMenuBarLabelLength = 16
    /// Without a cap, a typo like 100000 minutes generates thousands of blocks
    /// and hangs the timeline.
    private static let maxEstimateMinutes = 600

    private static let stampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    private static let clockFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private enum Key {
        static let history = "dayHistory"
        static let historyBackup = "dayHistoryBackup"
        static let showLabel = "showLabelInMenuBar"
        static let workMinutes = "workMinutes"
        static let shortBreakMinutes = "shortBreakMinutes"
        static let longBreakMinutes = "longBreakMinutes"
        static let dayStartHour = "dayStartHour"
        static let dayStartMinute = "dayStartMinute"
        static let autoStartNext = "autoStartNext"
        static let excludedCalendars = "excludedCalendarIDs"
        static let panelCollapsed = "panelCollapsed"
        static let activeBlock = "activeBlockID"
        static let isRunning = "isRunning"
        static let endDate = "endDate"
        static let remaining = "remaining"
        static let activeDuration = "activeDuration"
        static let completedPomodoros = "completedPomodoros"
        static let completedPomodorosDay = "completedPomodorosDay"
        static let breakEarnedAt = "pendingBreakEarnedAt"
        static let breakIsLong = "pendingBreakIsLong"
    }

    // MARK: - Init

    init(defaults: UserDefaults = .standard,
         calendar: (any PlannerCalendar)? = nil,
         now: @escaping () -> Date = Date.init,
         automaticallyUpdates: Bool = true,
         playCompletion: @escaping () -> Void = { NSSound(named: "Glass")?.play() }) {
        self.defaults = defaults
        self.calendar = calendar ?? CalendarService()
        self.now = now
        self.automaticallyUpdates = automaticallyUpdates
        self.playCompletion = playCompletion
        panelCollapsed = defaults.bool(forKey: Key.panelCollapsed)
        finishTimeEnabled = defaults.bool(forKey: "finishTimeEnabled")
        finishHour = min(23, max(0, defaults.object(forKey: "finishHour") as? Int ?? Self.defaultFinishHour))
        finishMinute = min(59, max(0, defaults.object(forKey: "finishMinute") as? Int ?? Self.defaultFinishMinute))
        showLabelInMenuBar = defaults.object(forKey: Key.showLabel) as? Bool ?? true
        workMinutes = defaults.object(forKey: Key.workMinutes) as? Int ?? 25
        shortBreakMinutes = defaults.object(forKey: Key.shortBreakMinutes) as? Int ?? 5
        longBreakMinutes = defaults.object(forKey: Key.longBreakMinutes) as? Int ?? 15
        dayStartHour = defaults.object(forKey: Key.dayStartHour) as? Int ?? 9
        dayStartMinute = defaults.object(forKey: Key.dayStartMinute) as? Int ?? 0
        autoStartNext = defaults.object(forKey: Key.autoStartNext) as? Bool ?? false
        excludedCalendarIDs = Set(defaults.stringArray(forKey: Key.excludedCalendars) ?? [])

        let decoded = Self.decodeHistory(defaults.string(forKey: Key.history))
        history = decoded.history
        if let corrupt = decoded.corrupt {
            // Keep the unreadable payload rather than letting the next save
            // overwrite it — otherwise one bad entry destroys every past day.
            defaults.set(corrupt, forKey: Key.historyBackup)
            historyLoadError = "saved task history couldn't be read; the raw copy was kept in '\(Key.historyBackup)'"
        }
        currentDayKey = Self.dayKey(for: now())
        recoverExpiredHistoricalWork()
        tasks = history[currentDayKey] ?? []

        // Today's pomodoro count and any break still owed. Yesterday's count
        // doesn't carry over.
        if defaults.string(forKey: Key.completedPomodorosDay) == currentDayKey {
            completedPomodoros = defaults.integer(forKey: Key.completedPomodoros)
        }
        if let earnedAt = defaults.object(forKey: Key.breakEarnedAt) as? Date {
            pendingBreak = (earnedAt, defaults.bool(forKey: Key.breakIsLong))
        }

        calendarAuthorized = self.calendar.isAuthorized
        // The first EventKit query is deferred until after launch. It runs on
        // the main actor, so doing it here would delay the menu bar item
        // appearing at all when the calendar is large.
        meetings = []

        // Meeting blocks don't exist until the deferred EventKit read. Keep
        // their saved state intact until that read can validate the event.
        if let id = defaults.string(forKey: Key.activeBlock) {
            let saved = SavedCountdown(id: id, running: defaults.bool(forKey: Key.isRunning),
                end: defaults.object(forKey: Key.endDate) as? Date,
                remaining: defaults.double(forKey: Key.remaining),
                duration: defaults.object(forKey: Key.activeDuration) as? TimeInterval)
            if id.hasPrefix("meeting-") {
                pendingMeetingRestore = saved
                reschedule()
            } else {
                restoreCountdown(saved)
            }
        } else {
            reschedule()
        }
        clock = now()
        startMinuteTimer()
        persistState()

        if automaticallyUpdates {
            Task { @MainActor in self.refreshCalendar(force: true) }
        }
    }

    private func restoreCountdown(_ saved: SavedCountdown) {
        activeBlockID = saved.id
        activeDuration = saved.duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        reschedule()
        guard let block = activeBlock, !block.isAllDay else {
            stopCountdown()
            return
        }
        activeDuration = block.isMeeting ? block.duration : (activeDuration ?? block.duration)
        // Calendar events keep their fixed end even if an older saved timer
        // was started late, or the event changed while the app was closed.
        let restoredEnd = block.isMeeting ? block.end : saved.end
        if saved.running, let end = restoredEnd, end > now() {
            remaining = end.timeIntervalSince(now())
            endDate = end
            isRunning = true
            lastPublishedSecond = -1
            startTicker()
        } else if saved.running, let end = restoredEnd {
            bankActiveBlock(endedAt: end)
            stopCountdown()
        } else if block.isMeeting {
            remaining = max(0, block.end.timeIntervalSince(now()))
            if remaining <= 0 { stopCountdown() }
        } else if saved.remaining > 0 {
            remaining = min(saved.remaining, activeDuration ?? block.duration)
        } else {
            stopCountdown()
        }
        reschedule()
    }

    // MARK: - Derived

    var activeBlock: ScheduledBlock? {
        guard let activeBlockID else { return nil }
        return blocks.first { $0.id == activeBlockID }
    }

    /// The next block that has not finished yet.
    var upcomingBlock: ScheduledBlock? {
        let now = self.now()
        return blocks.first { !$0.isAllDay && $0.end > now }
    }

    var displayBlock: ScheduledBlock? {
        activeBlock ?? upcomingBlock
    }

    var completedCount: Int {
        tasks.filter { $0.isDone }.count
    }

    /// Work still to do, leaving out blocks already finished.
    var plannedMinutesRemaining: Int {
        tasks.filter { !$0.isDone }.reduce(0) { $0 + $1.remainingMinutes }
    }

    /// Ticked-off tasks, most recently finished last, for the list under the
    /// plan where they can be unticked.
    var doneTasks: [DayTask] {
        tasks.filter(\.isDone).sorted { ($0.completedAt ?? .distantPast) < ($1.completedAt ?? .distantPast) }
    }

    /// A meeting starting soon enough to take over the menu bar countdown.
    var imminentMeeting: Meeting? {
        let now = self.now()
        return meetings
            .filter { !$0.isAllDay && $0.start > now }
            .filter { $0.start.timeIntervalSince(now) <= Self.imminentWindow }
            .min { $0.start < $1.start }
    }

    // MARK: - Menu bar

    var menuBarTime: String? {
        // A meeting only claims the countdown when it is imminent and no block
        // is already running.
        if !isRunning, imminentMeeting != nil { return nil }
        if activeBlock != nil { return Self.format(remaining) }
        if let upcomingBlock { return Self.format(upcomingBlock.duration) }
        return nil
    }

    /// Where the timeline should scroll to when the popover opens.
    ///
    /// Without this the list always starts at the day's first block, so anything
    /// hours away — a 5pm meeting on a 9am start — sits below the fold and looks
    /// like it is missing entirely.
    var anchorBlockID: ScheduledBlock.ID? {
        currentBlockID ?? blocks.first?.id
    }

    /// The imminent meeting when it has taken over the countdown, which it
    /// does only while nothing is running, as in the menu bar.
    var meetingTakeover: Meeting? {
        isRunning ? nil : imminentMeeting
    }

    /// The timeline row the panel treats as "now": the meeting when it has
    /// taken over, otherwise the block being counted down. One answer for the
    /// card, the orange bar and the scroll position, so they can't disagree.
    var currentBlockID: ScheduledBlock.ID? {
        if let meeting = meetingTakeover { return Scheduler.blockID(for: meeting) }
        return displayBlock?.id
    }

    var menuBarLabel: String {
        if !isRunning, let meeting = imminentMeeting {
            return Self.fit(meeting.title, to: Self.maxMenuBarLabelLength)
        }
        guard let block = displayBlock else { return "Plan your day" }
        if block.isBreak { return block.title }
        if let taskID = block.taskID, let task = tasks.first(where: { $0.id == taskID }) {
            let short = task.shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = short.isEmpty ? task.title : short
            return Self.fit(name.isEmpty ? block.title : name, to: Self.maxMenuBarLabelLength)
        }
        return Self.fit(block.title, to: Self.maxMenuBarLabelLength)
    }

    /// e.g. "in 12m" — pairs with an imminent meeting's title in the menu bar.
    var imminentMeetingSuffix: String? {
        guard !isRunning, let meeting = imminentMeeting else { return nil }
        let minutes = max(0, Int(ceil(meeting.start.timeIntervalSince(now()) / 60)))
        return minutes <= 0 ? "now" : "in \(minutes)m"
    }

    // MARK: - Task CRUD

    /// Adds a task, which lands in the plan by priority: ahead of anything
    /// less urgent, but never in front of the block being counted down.
    @discardableResult
    func addTask(title: String, minutes: Int, priority: TaskPriority = .leastUrgent) -> DayTask.ID? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let task = DayTask(title: trimmed, estimateMinutes: Self.clampEstimate(minutes), priority: priority)
        tasks.append(task)
        persistToday()
        reschedule()
        persistState()
        return task.id
    }

    /// The first timeline block belonging to a task, so the UI can scroll to it.
    func firstBlockID(for taskID: DayTask.ID) -> ScheduledBlock.ID? {
        blocks.first { $0.taskID == taskID }?.id
    }

    func updateTask(
        id: DayTask.ID,
        title: String,
        shortLabel: String,
        minutes: Int,
        priority: TaskPriority
    ) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        tasks[index].title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        tasks[index].shortLabel = shortLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        tasks[index].estimateMinutes = Self.clampEstimate(minutes)
        tasks[index].priority = priority

        // Cut to no more than has already been worked: there's nothing left
        // to plan, so it's done.
        if !tasks[index].isDone, tasks[index].remainingMinutes == 0 {
            let ownedActive = activeTaskID == id
            tasks[index].completedAt = now()
            if ownedActive { stopCountdown() }
        }
        persistToday()
        reschedule()
        persistState()
    }

    func deleteTask(id: DayTask.ID) {
        tasks.removeAll { $0.id == id }
        if activeTaskID == id { stopCountdown() }
        persistToday()
        reschedule()
        persistState()
    }

    /// Ticks a task off, or back on.
    ///
    /// Ticking off the task being counted down hands its time to the next
    /// one: the day is laid out again from now and, if the clock was running,
    /// the next task starts straight away. Unticking puts it back in the plan
    /// by priority.
    func toggleDone(id: DayTask.ID) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        let wasDone = tasks[index].isDone
        let ownedActive = activeTaskID == id
        let keepGoing = !wasDone && ownedActive && isRunning

        if wasDone {
            tasks[index].completedAt = nil
            // Finished by the clock, so nothing of it is left to plan. Give it
            // its whole estimate back, or unticking would show nothing.
            if tasks[index].remainingMinutes == 0 { tasks[index].completedMinutes = 0 }
        } else {
            tasks[index].completedAt = now()
            if ownedActive { stopCountdown() }
        }
        persistToday()
        reschedule()

        if keepGoing, let next = upcomingBlock, next.kind == .work {
            startBlock(next.id)
        } else {
            persistState()
        }
    }

    /// The task whose work block is being counted down, running or paused.
    private var activeTaskID: DayTask.ID? {
        guard let id = activeBlockID, let range = id.range(of: "-work-") else { return nil }
        return UUID(uuidString: String(id[..<range.lowerBound]))
    }

    private func stopCountdown() {
        stopTicker()
        isRunning = false
        endDate = nil
        activeBlockID = nil
        activeDuration = nil
        pendingMeetingRestore = nil
        remaining = 0
    }

    func clearCompleted() {
        tasks.removeAll { $0.isDone }

        // If the running block belonged to a task that just disappeared, stop.
        if let block = activeBlock, !activeBlockStillExists(block) {
            stopCountdown()
        }
        persistToday()
        reschedule()
        persistState()
    }

    /// Removes every task for today, and stops anything counting down.
    ///
    /// Past days are kept — this clears the day you're looking at, not your
    /// history.
    func clearAll() {
        stopCountdown()
        pendingBreak = nil
        persistProgress()

        tasks.removeAll()
        meetings = calendar.isAuthorized ? calendar.meetings(on: now(), excluding: excludedCalendarIDs) : []

        persistToday()
        reschedule()
        persistState()
    }

    private func activeBlockStillExists(_ block: ScheduledBlock) -> Bool {
        guard let taskID = block.taskID else { return true }
        return tasks.contains { $0.id == taskID }
    }

    // MARK: - Countdown

    func startBlock(_ id: ScheduledBlock.ID) {
        guard var block = blocks.first(where: { $0.id == id }), !block.isAllDay else { return }
        if block.isMeeting, block.end <= now() {
            if activeBlockID == block.id {
                stopCountdown()
                reschedule()
                persistState()
            }
            return
        }
        pendingMeetingRestore = nil

        // Any of a task's blocks means "work on this task now", which is its
        // next block. Starting a later one would leave the earlier one ahead
        // of it in the plan.
        if block.kind == .work, let taskID = block.taskID,
           let next = blocks.first(where: { $0.kind == .work && $0.taskID == taskID }) {
            block = next
        }

        let changed = activeBlockID != block.id
        if changed {
            activeBlockID = block.id
            activeDuration = block.duration
            remaining = block.duration
            lastPublishedSecond = -1
            // Getting back to work skips whatever was left of the break.
            if block.kind == .work { pendingBreak = nil }
        }
        if block.isMeeting {
            remaining = block.end.timeIntervalSince(now())
        }

        if !isRunning {
            if remaining <= 0 { remaining = activeDuration ?? block.duration }
            endDate = block.isMeeting ? block.end : now().addingTimeInterval(remaining)
            isRunning = true
            startTicker()
        } else if changed {
            // Switched to another block mid-countdown: it gets its own full
            // time, rather than whatever was left of the one before.
            endDate = block.isMeeting ? block.end : now().addingTimeInterval(remaining)
        }
        // The task being worked on goes to the front of the plan, starting
        // now, and everything else moves to fit around it.
        reschedule()
        persistState()
    }

    func pause() {
        guard isRunning else { return }
        if let endDate { remaining = max(0, endDate.timeIntervalSince(now())) }
        isRunning = false
        endDate = nil
        stopTicker()
        persistState()
    }

    func toggleRunPause() {
        if isRunning {
            pause()
        } else {
            // An unstarted task does not expire with its old planned slot.
            if activeBlockID == nil { reschedule() }
            if let id = activeBlockID ?? upcomingBlock?.id { startBlock(id) }
        }
    }

    func resetActive() {
        pause()
        guard let block = activeBlock else { return }
        remaining = block.isMeeting ? max(0, block.end.timeIntervalSince(now())) : (activeDuration ?? block.duration)
        if block.isMeeting, remaining <= 0 { stopCountdown() }
        // Work and breaks reset to their full length; meetings keep their end.
        reschedule()
        persistState()
    }

    func tick() {
        guard isRunning, let endDate else { return }
        let raw = endDate.timeIntervalSince(now())
        let second = max(0, Int(ceil(raw)))

        if second != lastPublishedSecond {
            lastPublishedSecond = second
            remaining = max(0, raw)
            clock = now()
        }
        if raw <= 0 { completeActiveBlock() }
    }

    private func completeActiveBlock() {
        playCompletion()
        bankActiveBlock(endedAt: endDate ?? now())
        stopCountdown()
        reschedule()

        // Chain into the next block if the user asked for it. Meetings are
        // skipped: they happen at a fixed time, so starting one early would be
        // a countdown to nothing.
        if autoStartNext, let next = upcomingBlock, !next.isMeeting {
            startBlock(next.id)
        } else {
            persistState()
        }
    }

    /// Records a block that ran to the end. A work block's minutes count
    /// towards its task, which is done once they cover the estimate, and the
    /// break it earned goes first in the plan. A finished break is taken.
    private func bankActiveBlock(endedAt: Date) {
        guard let block = activeBlock else { return }
        switch block.kind {
        case .work:
            if let taskID = block.taskID,
               let index = tasks.firstIndex(where: { $0.id == taskID }),
               !tasks[index].isDone {
                tasks[index].completedMinutes += Int(((activeDuration ?? block.duration) / 60).rounded())
                tasks[index].completedBlocks += 1
                if tasks[index].remainingMinutes == 0 {
                    tasks[index].completedAt = endedAt
                }
                persistToday()
            }
            completedPomodoros += 1
            pendingBreak = (endedAt, completedPomodoros % Self.pomodorosBeforeLongBreak == 0)
        case .shortBreak, .longBreak:
            pendingBreak = nil
        case .meeting:
            break
        }
        persistProgress()
    }

    // MARK: - Calendar

    func connectCalendar() async {
        await calendar.requestAccess()
        calendarAuthorized = calendar.isAuthorized
        calendarError = calendar.lastError
        refreshCalendar(force: true)
    }

    func refreshCalendar(force: Bool = false) {
        calendarAuthorized = calendar.isAuthorized
        calendarError = calendar.lastError

        guard calendarAuthorized else {
            meetings = []
            pendingMeetingRestore = nil
            if activeBlock?.isMeeting == true { stopCountdown() }
            reschedule()
            persistState()
            return
        }
        if !force, now().timeIntervalSince(lastCalendarRefresh) < Self.calendarRefreshInterval {
            return
        }
        lastCalendarRefresh = now()
        meetings = calendar.meetings(on: now(), excluding: excludedCalendarIDs)
        reschedule()
        if isRunning, let block = activeBlock, block.isMeeting {
            // Calendar edits can shorten or extend an event while it runs.
            activeDuration = block.duration
            endDate = block.end
            tick()
        }
        if let saved = pendingMeetingRestore {
            pendingMeetingRestore = nil
            restoreCountdown(saved)
        }
        persistState()
    }

    // MARK: - Scheduling

    private func reschedule() {
        // Lay the remaining work out from whichever is later: the configured day
        // start, or now.
        //
        // Anchoring on 09:00 alone means that at 2pm every remaining task — and
        // anything you just added — is scheduled into the past, so it renders
        // greyed out above the visible area. Adding a task then looks like it
        // did nothing.
        let now = self.now()
        var start = max(dayStartDate, now)

        // The block being counted down is laid out from when it really
        // started, so its row ends when the countdown does. Looked up in the
        // previous layout; at launch there is none yet, so it starts now.
        let elapsed = activeBlock.map { max(0, (activeDuration ?? $0.duration) - currentRemaining) } ?? 0
        let workingOn = activeTaskID
        if workingOn != nil { start = now.addingTimeInterval(-elapsed) }

        // A break owed from the last finished block. Once its time has passed
        // without being started, it has been taken.
        var owedBreak: Scheduler.PendingBreak?
        if let owed = pendingBreak {
            let id = Self.breakID(earnedAt: owed.earnedAt)
            let length = TimeInterval((owed.isLong ? longBreakMinutes : shortBreakMinutes) * 60)
            if activeBlockID == id {
                owedBreak = .init(start: now.addingTimeInterval(-elapsed), isLong: owed.isLong, id: id,
                                  minutes: activeDuration.flatMap { Int(exactly: ($0 / 60).rounded()) })
            } else if now < owed.earnedAt.addingTimeInterval(length) {
                owedBreak = .init(start: owed.earnedAt, isLong: owed.isLong, id: id)
            } else {
                pendingBreak = nil
                persistProgress()
            }
        }

        // Completed tasks are dropped rather than kept at their planned times:
        // their slots are in the past, and holding them open pushes live work
        // further down the list. They're listed under the plan instead.
        let outstanding = tasks.filter { !$0.isDone }

        blocks = Scheduler.buildDay(
            tasks: outstanding,
            meetings: meetings,
            dayStart: start,
            settings: Scheduler.Settings(
                workMinutes: workMinutes,
                shortBreakMinutes: shortBreakMinutes,
                longBreakMinutes: longBreakMinutes,
                pomodorosBeforeLongBreak: Self.pomodorosBeforeLongBreak
            ),
            pendingBreak: owedBreak,
            firstTaskID: workingOn,
            firstBlockMinutes: workingOn == nil ? nil : activeDuration.flatMap { Int(exactly: ($0 / 60).rounded()) },
            completedPomodoros: completedPomodoros
        )
        if let id = activeBlockID, !blocks.contains(where: { $0.id == id }) {
            // The running block no longer exists — the task was edited, or the
            // work-block length changed. Stop the countdown too, otherwise the
            // app is left "running" with nothing to run: `startBlock` bails on
            // `guard !isRunning`, so Start would silently do nothing (and the
            // first press would actually pause the invisible timer).
            stopCountdown()
        }
        writeDiagnostics()
    }

    /// Time left on the countdown, live while it runs.
    private var currentRemaining: TimeInterval {
        if isRunning, let endDate { return max(0, endDate.timeIntervalSince(now())) }
        return remaining
    }

    private static let pomodorosBeforeLongBreak = 4

    private static func breakID(earnedAt: Date) -> String {
        "break-\(Int(earnedAt.timeIntervalSince1970))"
    }

    /// Structured self-report of everything the UI is derived from.
    ///
    /// The app can't be screenshotted from a sandboxed shell, so rather than
    /// asking what the interface looks like, it records what it actually
    /// computed. Read it with:
    ///
    ///     defaults read local.pomodoro.menubar diagnostics
    private func writeDiagnostics() {
        // Cached: building a DateFormatter is expensive, and this runs on every
        // reschedule.
        let stamp = Self.stampFormatter
        let clock = Self.clockFormatter

        var out: [String] = []
        out.append("generated: \(stamp.string(from: now()))")
        out.append("day: \(currentDayKey)")
        out.append(String(format: "dayStart: %02d:%02d", dayStartHour, dayStartMinute))
        if let historyLoadError { out.append("historyLoadError: \(historyLoadError)") }
        out.append("layout: \(layoutReport)")
        out.append("")

        out.append("CALENDAR")
        out.append("  authorized: \(calendarAuthorized)")
        out.append("  status: \(calendar.statusDescription)")
        if let calendarError { out.append("  error: \(calendarError)") }
        out.append("  meetings returned: \(meetings.count)")
        // Keep only aggregate calendar diagnostics: event text, identifiers
        // and times must not be copied into persistent debug output.
        out.append("")

        out.append("TASKS (\(tasks.count), \(completedCount) done)")
        for task in tasks {
            out.append(
                "  [\(task.isDone ? "x" : " ")] \(task.title)  \(task.estimateMinutes)m"
                + "  priority=\(task.priority.name)  worked=\(task.completedMinutes)m"
            )
        }
        out.append("  pomodoros today: \(completedPomodoros)")
        if let pendingBreak {
            out.append("  break owed: since \(clock.string(from: pendingBreak.earnedAt)), long=\(pendingBreak.isLong)")
        }
        out.append("")

        out.append("TIMELINE (\(blocks.count) blocks)")
        for block in blocks where !block.isMeeting {
            let kind = block.kind.rawValue.padding(toLength: 11, withPad: " ", startingAt: 0)
            out.append(
                "  \(clock.string(from: block.start))-\(clock.string(from: block.end))"
                + "  \(kind)\(block.title)"
            )
        }
        out.append("")

        out.append("MENU BAR")
        let showsMeeting = meetingTakeover != nil || displayBlock?.isMeeting == true
        let anchorIsMeeting = blocks.first { $0.id == anchorBlockID }?.isMeeting == true
        out.append("  label: \(showsMeeting ? "[calendar event]" : menuBarLabel)")
        out.append("  time: \(showsMeeting ? "[calendar event]" : (menuBarTime ?? "-"))")
        out.append("  imminentMeeting: \(imminentMeeting != nil)")
        out.append("  anchorBlockID: \(anchorIsMeeting ? "[calendar event]" : (anchorBlockID ?? "-"))")
        out.append("  isRunning: \(isRunning)")
        out.append("")

        out.append("APP")
        out.append("  activationPolicy: \(Self.activationPolicyName)")
        let windows = NSApplication.shared.windows
        out.append("  windows: \(windows.count) total, \(windows.filter(\.isVisible).count) visible")

        defaults.set(out.joined(separator: "\n"), forKey: "diagnostics")

        // Retired ad-hoc keys from earlier debugging.
        for stale in ["debugTimeline", "debugMeetingCount", "debugMeetings"] {
            defaults.removeObject(forKey: stale)
        }
    }

    private var dayStartDate: Date {
        let calendar = Calendar.current
        var components = calendar.dateComponents([.year, .month, .day], from: now())
        components.hour = dayStartHour
        components.minute = dayStartMinute
        return calendar.date(from: components) ?? calendar.startOfDay(for: now())
    }

    // MARK: - Timers

    private func startTicker() {
        stopTicker()
        guard automaticallyUpdates else { return }
        let ticker = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(ticker, forMode: .common)
        self.ticker = ticker
    }

    private func stopTicker() {
        ticker?.invalidate()
        ticker = nil
    }

    /// Once a minute: day rollover, calendar refresh, and a UI pulse so
    /// time-dependent labels update while idle.
    private func startMinuteTimer() {
        minuteTimer?.invalidate()
        guard automaticallyUpdates else { return }
        let timer = Timer(timeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.clock = self.now()
                self.checkForNewDay()
                self.refreshCalendar()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        minuteTimer = timer
    }

    // MARK: - Day rollover

    func checkForNewDay() {
        let today = Self.dayKey(for: now())
        guard today != currentDayKey else { return }

        history[currentDayKey] = tasks
        saveHistory()

        currentDayKey = today
        tasks = history[today] ?? []

        stopCountdown()
        lastPublishedSecond = -1
        completedPomodoros = 0
        pendingBreak = nil
        persistProgress()

        meetings = calendar.meetings(on: now(), excluding: excludedCalendarIDs)
        reschedule()
        persistToday()
        persistState()
    }

    // MARK: - Persistence

    /// Recover finished work before selecting today's tasks. Its owner may
    /// only exist in yesterday's history, which today's timeline cannot find.
    private func recoverExpiredHistoricalWork() {
        guard defaults.bool(forKey: Key.isRunning),
              let end = defaults.object(forKey: Key.endDate) as? Date, end <= now(),
              let id = defaults.string(forKey: Key.activeBlock) else { return }

        for day in history.keys where day != currentDayKey {
            guard var dayTasks = history[day],
                  let index = dayTasks.firstIndex(where: {
                      !$0.isDone && id == "\($0.id.uuidString)-work-\(max(0, $0.completedBlocks) + 1)"
                  }) else { continue }

            let frozenMinutes = (defaults.object(forKey: Key.activeDuration) as? TimeInterval)
                .flatMap { $0.isFinite && $0 > 0 ? Int(exactly: ($0 / 60).rounded()) : nil }
            let minutes = frozenMinutes ?? min(max(1, workMinutes), dayTasks[index].remainingMinutes,
                                               Scheduler.maxTaskMinutes)
            dayTasks[index].completedMinutes += minutes
            dayTasks[index].completedBlocks += 1
            if dayTasks[index].remainingMinutes == 0 {
                dayTasks[index].completedAt = end
            }
            history[day] = dayTasks
            // Advancing completedBlocks also makes a repeat recovery harmless
            // if the app exits before clearing the saved countdown below.
            saveHistory()
            return
        }
    }

    private func persistToday() {
        history[currentDayKey] = tasks
        saveHistory()
    }

    private func persistSettings() {
        defaults.set(workMinutes, forKey: Key.workMinutes)
        defaults.set(shortBreakMinutes, forKey: Key.shortBreakMinutes)
        defaults.set(longBreakMinutes, forKey: Key.longBreakMinutes)
        defaults.set(dayStartHour, forKey: Key.dayStartHour)
        defaults.set(dayStartMinute, forKey: Key.dayStartMinute)
    }

    /// Today's pomodoro count and the break owed, so a relaunch keeps both.
    private func persistProgress() {
        defaults.set(completedPomodoros, forKey: Key.completedPomodoros)
        defaults.set(currentDayKey, forKey: Key.completedPomodorosDay)
        if let pendingBreak {
            defaults.set(pendingBreak.earnedAt, forKey: Key.breakEarnedAt)
            defaults.set(pendingBreak.isLong, forKey: Key.breakIsLong)
        } else {
            defaults.removeObject(forKey: Key.breakEarnedAt)
            defaults.removeObject(forKey: Key.breakIsLong)
        }
    }

    private func persistState() {
        guard pendingMeetingRestore == nil else { return }
        defaults.set(activeDuration, forKey: Key.activeDuration)
        defaults.set(activeBlockID, forKey: Key.activeBlock)
        defaults.set(isRunning, forKey: Key.isRunning)
        defaults.set(remaining, forKey: Key.remaining)
        if let endDate {
            defaults.set(endDate, forKey: Key.endDate)
        } else {
            defaults.removeObject(forKey: Key.endDate)
        }
    }

    /// Stored as a JSON *string* rather than `Data` so the contents stay
    /// readable via `defaults read` while developing.
    private func saveHistory() {
        guard let data = try? JSONEncoder().encode(history),
              let json = String(data: data, encoding: .utf8) else { return }
        defaults.set(json, forKey: Key.history)
    }

    /// Returns the decoded history plus, on failure, the raw payload so the
    /// caller can preserve it. Silently returning `[:]` would let the next save
    /// overwrite the stored history permanently.
    private static func decodeHistory(
        _ json: String?
    ) -> (history: [String: [DayTask]], corrupt: String?) {
        guard let json, !json.isEmpty else { return ([:], nil) }
        guard let data = json.data(using: .utf8),
              let decoded = try? JSONDecoder().decode([String: [DayTask]].self, from: data)
        else { return ([:], json) }
        return (decoded, nil)
    }

    private static func clampEstimate(_ minutes: Int) -> Int {
        min(max(1, minutes), maxEstimateMinutes)
    }

    /// Re-writes the self-report. Called when a surface appears, so the dump
    /// reflects the current window and activation state rather than launch time.
    func refreshDiagnostics() {
        writeDiagnostics()
    }

    private static var activationPolicyName: String {
        switch NSApplication.shared.activationPolicy() {
        case .regular: return "regular (Dock icon present)"
        case .accessory: return "accessory (menu bar only)"
        case .prohibited: return "prohibited"
        @unknown default: return "unknown"
        }
    }

    // MARK: - Formatting

    private static func dayKey(for date: Date) -> String {
        let parts = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    static func format(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(ceil(seconds)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private static func fit(_ text: String, to limit: Int) -> String {
        text.count > limit ? String(text.prefix(limit - 1)) + "\u{2026}" : text
    }
}
