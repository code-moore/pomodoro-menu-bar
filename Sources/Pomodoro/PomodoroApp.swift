import SwiftUI
import AppKit
import PomodoroCore

@main
struct PomodoroApp: App {
    @StateObject private var planner: DayPlanner
    @StateObject private var updates: UpdateController

    init() {
        #if !APP_STORE
        PreferenceMigration.migrate()
        #endif
        _planner = StateObject(wrappedValue: DayPlanner())
        _updates = StateObject(wrappedValue: UpdateController())
    }

    var body: some Scene {
        MenuBarExtra {
            DayPlanMenu(planner: planner, updates: updates)
        } label: {
            // Text concatenation, not an HStack: a MenuBarExtra label is fitted
            // into an NSStatusItem and SwiftUI squashes composite labels when the
            // menu bar is tight. One Text measures at its true width.
            menuBarLabel
                .fixedSize()
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarLabel: Text {
        let label = planner.menuBarLabel

        // An imminent meeting takes over the countdown entirely — but the
        // "Label" switch still decides whether its name is shown.
        if let suffix = planner.imminentMeetingSuffix {
            let time = Text(suffix).monospacedDigit()
            return planner.showLabelInMenuBar ? Text(label) + Text("  ") + time : time
        }

        guard planner.showLabelInMenuBar else {
            return planner.menuBarTime.map { Text($0).monospacedDigit() } ?? Text(label)
        }
        guard let time = planner.menuBarTime else { return Text(label) }
        return Text(label) + Text("  ") + Text(time).monospacedDigit()
    }
}


// MARK: - Popover

struct DayPlanMenu: View {
    @ObservedObject var planner: DayPlanner
    @ObservedObject var updates: UpdateController

    @State private var newTitle = ""
    @State private var newHours = ""
    @State private var newMinutes = ""
    /// Kept between tasks, like the duration boxes.
    @State private var newPriority: TaskPriority = .leastUrgent
    @State private var showSettings = false
    /// Set just after a task is added, so the timeline scrolls to it.
    @State private var pendingScrollID: ScheduledBlock.ID?
    /// The row the user clicked, which shows its Delete button.
    @State private var selectedBlockID: ScheduledBlock.ID?
    /// Gates the destructive "clear everything" action.
    @State private var pendingClearAll = false
    /// When a task was last ticked or unticked. Ticking one off moves the
    /// next row up under the pointer, so the second click of a double-click
    /// would tick that one off too.
    @State private var lastTickAt = Date.distantPast

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            // What is counting down now, and what the day looks like.
            VStack(alignment: .leading, spacing: 14) {
                header
                controls

                // The footer's fold chevron has to stay reachable, so with the
                // list folded away the footer moves up into this card.
                if planner.panelCollapsed {
                    ThemeDivider()
                    footer
                }
            }
            .padding(18)
            .raised(cornerRadius: 22)

            // Adding work, and the timeline it lands in. Folded away by the
            // chevron beside Quit, leaving the countdown box above.
            if !planner.panelCollapsed {
                VStack(alignment: .leading, spacing: 14) {
                    addRow
                    ThemeDivider()
                    timeline
                        .padding(.horizontal, -14)
                    ThemeDivider()
                    footer
                }
                .padding(EdgeInsets(top: 18, leading: 14, bottom: 14, trailing: 14))
                .raised(cornerRadius: 22)
            }
        }
        // Room for the cards' shade, which would otherwise be clipped at the
        // panel's edge.
        .padding(20)
        // Roomy enough to show a full working day without scrolling, which is
        // what the separate window used to provide. Wider than the content
        // strictly needs, to give back what the card padding takes from titles.
        .frame(width: 540)
        // No background of its own: the panel's glass shows through, and the
        // theme colours follow Light and Dark mode with it.
        .tint(Theme.accent)
        .background(
            GeometryReader { proxy in
                Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                    measuredContainer = size
                }
            }
        )
        // Opens in the same place whatever the menu bar item says.
        .background(PanelAnchor())
        .onChange(of: measuredContainer) { _, _ in reportLayout() }
        .onChange(of: measuredTimeline) { _, _ in reportLayout() }
        .onAppear {
            planner.checkForNewDay()
            planner.refreshCalendar(force: true)
            planner.refreshDiagnostics()
        }
    }

    @State private var measuredContainer = CGSize.zero
    @State private var measuredTimeline = CGSize.zero
    /// Natural height of the rows inside the ScrollView, measured rather than
    /// guessed, so the frame can match it exactly.
    @State private var measuredContentHeight: CGFloat = 0

    private func reportLayout() {
        planner.recordLayout(container: measuredContainer, timeline: measuredTimeline)
    }

    // MARK: Header

    /// The countdown leads the panel, where a "Today" title used to be, with
    /// the day's totals and calendar opposite.
    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            clock

            Spacer(minLength: 12)

            VStack(alignment: .trailing, spacing: 8) {
                Text(summary)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .monospacedDigit()

                // Calendar status sits at the top: it's context for the whole
                // day, not a footnote.
                calendarRow
            }
        }
    }

    private var summary: String {
        guard !planner.tasks.isEmpty else { return "nothing planned" }
        let remaining = Self.durationText(planner.plannedMinutesRemaining)
        return "\(planner.completedCount)/\(planner.tasks.count) done · \(remaining) of work left"
    }

    /// "145m" reads badly next to a clock; hours and minutes is clearer.
    static func durationText(_ minutes: Int) -> String {
        let hours = minutes / 60
        let remainder = minutes % 60
        if hours == 0 { return "\(remainder)m" }
        if remainder == 0 { return "\(hours)h" }
        return "\(hours)h \(remainder)m"
    }

    // MARK: Countdown

    private var clock: some View {
        Group {
            if let meeting = planner.meetingTakeover {
                // Idle with a meeting coming up: count down to it, instead of
                // falling back to "0:00". Nothing else ticks while idle, so
                // this redraws itself every second.
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = meeting.start.timeIntervalSince(context.date)
                    // Once it has started, say so rather than sit at 0:00
                    // until the panel next refreshes.
                    clockText(left > 0 ? DayPlanner.format(left) : "Now")
                }
            } else {
                clockText(planner.menuBarTime ?? "0:00")
            }
        }
    }

    private func clockText(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 46, weight: .semibold))
            .tracking(-1.5)
            .monospacedDigit()
            .contentTransition(.numericText())
    }

    /// What the clock is counting down, in the card's bottom-right corner:
    /// its name above its times, after an imminent meeting's "in N minutes"
    /// warning. A meeting only takes over while nothing is running, so this
    /// always names whatever the clock is showing.
    private var currentBlock: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if let meeting = planner.meetingTakeover {
                if let suffix = planner.imminentMeetingSuffix {
                    Text(suffix)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Theme.warning)
                }
                blockTitle(meeting.title, isCurrent: true)
                blockDetails(BlockRow.range(meeting.start, meeting.end, allDay: meeting.isAllDay))
            } else if let block = planner.displayBlock {
                blockTitle(block.title.isEmpty ? "Untitled" : block.title,
                           isCurrent: planner.activeBlock != nil)
                blockDetails(BlockRow.range(block))
            } else {
                blockTitle("Add a task below to build your day", isCurrent: false)
            }
        }
        // Leaves the buttons their room; a long name wraps instead.
        .frame(maxWidth: 290, alignment: .trailing)
    }

    private func blockTitle(_ title: String, isCurrent: Bool) -> some View {
        Text(title)
            .font(.system(size: 14, weight: .medium))
            .lineLimit(2)
            .multilineTextAlignment(.trailing)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(isCurrent ? Theme.text : Theme.secondaryText)
    }

    /// Slate, like the rest of the card's supporting text; only the block's
    /// name is in the body colour.
    private func blockDetails(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12))
            .foregroundStyle(Theme.accent)
            .monospacedDigit()
    }

    private var controls: some View {
        // Bottom-aligned, so the block's times sit level with the buttons.
        HStack(alignment: .bottom, spacing: 10) {
            Button {
                planner.toggleRunPause()
            } label: {
                Image(systemName: planner.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 14, weight: .semibold))
                    // Icon only, but as wide as the old "Start" pill, so it
                    // still reads as the main control.
                    .frame(width: 52)
            }
            .buttonStyle(PrimaryButtonStyle())
            .keyboardShortcut(.defaultAction)
            .disabled(planner.blocks.isEmpty)
            .help(planner.isRunning ? "Pause" : "Start")
            .accessibilityLabel(planner.isRunning ? "Pause" : "Start")

            Button {
                planner.resetActive()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 13, weight: .semibold))
            }
            .buttonStyle(SoftButtonStyle(circular: true))
            .disabled(planner.activeBlock == nil)
            .help("Reset")
            .accessibilityLabel("Reset")

            Spacer(minLength: 16)

            currentBlock
        }
    }

    // MARK: Add

    private var addRow: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("New task", text: $newTitle)
                .font(.system(size: 14))
                .insetField(height: 36)

            HStack(spacing: 10) {
                DurationField(unit: .hours, text: $newHours)
                DurationField(unit: .minutes, text: $newMinutes)

                PriorityPicker(selection: $newPriority)

                Spacer()

                Button("Add", action: addTask)
                    .buttonStyle(SoftButtonStyle())
                    .disabled(!canAddTask)
            }
        }
        // Return in any of the three boxes adds the task. A box without its
        // own submit action lets Return fall through to the panel's default
        // button, which is Start: typing a duration and pressing Return used
        // to start the timer instead.
        .onSubmit(addTask)
        .padding(.horizontal, 4)
    }

    private var canAddTask: Bool {
        !newTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && newTaskMinutes != nil
    }

    /// What the new task asks for. With both boxes empty it gets one work
    /// block, so a name alone is enough to add a task.
    private var newTaskMinutes: Int? {
        if newHours.isEmpty && newMinutes.isEmpty { return planner.workMinutes }
        return DurationInput.total(hours: newHours, minutes: newMinutes)
    }

    // MARK: Timeline

    private var timelineRows: [TimelineRow] {
        let expandedTaskID = planner.blocks.first { $0.id == selectedBlockID }?.taskID
        return TimelineRow.make(blocks: planner.blocks, expandedTaskID: expandedTaskID)
    }

    private var timeline: some View {
        ScrollViewReader { proxy in
            ScrollView {
                // Deliberately NOT a LazyVStack: it renders fewer rows than a
                // VStack here, and the estimate clamp already bounds the count.
                VStack(alignment: .leading, spacing: 2) {
                    // Worked out once, not per row: it scans the blocks.
                    let currentID = planner.currentBlockID
                    let rows = timelineRows
                    let finishRowIndex = planner.finishTime.flatMap {
                        TimelineRow.finishIndex(in: rows, at: $0)
                    }
                    let finishRowID = finishRowIndex.map { rows[$0].id }
                    let greyedRowIDs = Set(finishRowIndex.map {
                        rows[$0...].map(\.id)
                    } ?? [])

                    if planner.blocks.isEmpty {
                        Text(planner.tasks.isEmpty ? "No blocks yet. Add a task above."
                                                   : "All done. Add a task above to plan more.")
                            .font(.system(size: 13))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.vertical, 8)
                            .padding(.horizontal, 10)
                    } else {
                        ForEach(rows) { row in
                            let block = row.block
                            if let finish = planner.finishTime, row.id == finishRowID {
                                finishMarker(finish)
                            }
                            let task = block.taskID.flatMap { id in planner.tasks.first { $0.id == id } }
                            BlockRow(
                                block: block,
                                isActive: planner.activeBlockID.map { row.blockIDs.contains($0) } ?? false,
                                isCurrent: currentID.map { row.blockIDs.contains($0) } ?? false,
                                isRunning: block.id == planner.activeBlockID && planner.isRunning,
                                isPast: block.end <= planner.clock,
                                canEditTask: block.taskID != nil,
                                taskIsDone: task?.isDone ?? false,
                                taskTitle: task?.title ?? block.title,
                                taskEstimateMinutes: task?.estimateMinutes ?? 0,
                                taskPriority: task?.priority ?? .leastUrgent,
                                isSelected: selectedBlockID == block.id,
                                displayMinutes: row.minutes,
                                onStart: {
                                    if block.id == planner.activeBlockID {
                                        planner.toggleRunPause()
                                    } else {
                                        planner.startBlock(block.id)
                                    }
                                },
                                onToggleDone: {
                                    guard let taskID = block.taskID else { return }
                                    tick(taskID)
                                },
                                onDeleteTask: {
                                    guard let taskID = block.taskID else { return }
                                    selectedBlockID = nil
                                    planner.deleteTask(id: taskID)
                                },
                                onUpdateTask: { title, minutes, priority in
                                    guard let task else { return }
                                    planner.updateTask(
                                        id: task.id,
                                        title: title,
                                        shortLabel: task.shortLabel,
                                        minutes: minutes,
                                        priority: priority
                                    )
                                    selectedBlockID = nil
                                },
                                onSelect: {
                                    // Only task rows are selectable; calendar
                                    // events have nothing to reveal.
                                    guard block.taskID != nil else { return }
                                    selectedBlockID = (selectedBlockID == block.id) ? nil : block.id
                                }
                            )
                            .saturation(greyedRowIDs.contains(row.id) ? 0 : 1)
                            .opacity(greyedRowIDs.contains(row.id) ? 0.6 : 1)
                            .id(block.id)
                        }
                    }

                    if let finish = planner.finishTime, finishRowID == nil {
                        finishMarker(finish)
                    }

                    // Ticked-off tasks, under the plan, where they can be
                    // unticked or cleared.
                    if !planner.doneTasks.isEmpty {
                        Text("Done")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(Theme.secondaryText)
                            .padding(.top, 8)
                            .padding(.horizontal, 10)
                            .opacity(planner.finishTimeEnabled ? 0.6 : 1)

                        ForEach(planner.doneTasks) { task in
                            DoneRow(
                                task: task,
                                isSelected: selectedBlockID == DoneRow.rowID(task.id),
                                onToggleDone: { tick(task.id) },
                                onDelete: {
                                    selectedBlockID = nil
                                    planner.deleteTask(id: task.id)
                                },
                                onSelect: {
                                    let id = DoneRow.rowID(task.id)
                                    selectedBlockID = (selectedBlockID == id) ? nil : id
                                }
                            )
                            .saturation(planner.finishTimeEnabled ? 0 : 1)
                            .opacity(planner.finishTimeEnabled ? 0.6 : 1)
                        }
                    }
                }
                // Room for the active row's raised shade, which the ScrollView
                // would otherwise clip.
                .padding(.vertical, 4)
                .padding(.horizontal, 18)
                // Measure the rows' natural height so the frame below can match
                // it exactly — no guessed per-row constant, no dead space.
                .background(
                    GeometryReader { proxy in
                        Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                            if abs(size.height - measuredContentHeight) > 0.5 {
                                measuredContentHeight = size.height
                            }
                        }
                    }
                )
                // Scrolled to the end, the last row clears the bottom fade.
                // Added after the measurement, so it can't feed back into
                // whether the list overflows: when it was counted, a list
                // that shrank to fit stayed scrollable with the fade still on.
                .padding(.bottom, timelineOverflows ? Self.fadeHeight : 0)
            }
            .frame(height: timelineHeight)
            // When the day overflows, fade the bottom edge so the list reads as
            // continuing rather than as a row sliced in half.
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .black, location: 0),
                        .init(color: .black,
                              location: timelineOverflows ? 1 - Self.fadeHeight / timelineHeight : 1),
                        .init(color: timelineOverflows ? .clear : .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .background(
                GeometryReader { proxy in
                    Color.clear.onChange(of: proxy.size, initial: true) { _, size in
                        measuredTimeline = size
                    }
                }
            )
            .onAppear {
                // Jump to whatever is happening now instead of the top of the day.
                if let anchor = planner.anchorBlockID {
                    proxy.scrollTo(timelineRows.first { $0.blockIDs.contains(anchor) }?.id ?? anchor, anchor: .top)
                }
            }
            .onChange(of: pendingScrollID) { _, target in
                // A newly added task lands at the end of the queue, which may be
                // below the fold — without this it looks like nothing happened.
                guard let target else { return }
                withAnimation { proxy.scrollTo(target, anchor: .center) }
            }
        }
    }

    /// A definite height for the timeline: never zero, and never more than the
    /// rows actually need. `maxHeight` alone sets no floor (so the timeline
    /// could silently vanish), while a guessed per-row constant left dead space
    /// at the bottom — so the content is measured and used directly.
    private var timelineHeight: CGFloat {
        guard !planner.blocks.isEmpty || !planner.doneTasks.isEmpty else { return 40 }
        let wanted = measuredContentHeight > 1
            ? measuredContentHeight
            : CGFloat(planner.blocks.count + planner.doneTasks.count) * 24
        return min(wanted, timelineCap)
    }

    private static let fadeHeight: CGFloat = 24

    private var timelineOverflows: Bool {
        measuredContentHeight > timelineHeight + 1
    }

    private var timelineCap: CGFloat {
        // Everything above and below the timeline (cards, padding, footer)
        // takes roughly this much of the screen.
        let screenCap = (NSScreen.main?.visibleFrame.height ?? 900) - 492
        return max(120, min(460, screenCap))
    }

    // MARK: Calendar

    private var calendarRow: some View {
        // Right-aligned, under the day summary. There's no Refresh button: the
        // calendar is re-read every time the panel opens, and every five
        // minutes while the app runs.
        HStack(spacing: 8) {
            Image(systemName: planner.calendarAuthorized ? "calendar" : "calendar.badge.exclamationmark")
                .font(.system(size: 12))
                .foregroundStyle(planner.calendarAuthorized ? Theme.accent : Theme.warning)

            if planner.calendarAuthorized {
                Text(meetingSummary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
            } else {
                Text(planner.calendarError ?? "Calendar not connected, so meetings won't appear")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.accent)
                    .multilineTextAlignment(.trailing)
                    .lineLimit(2)
                    // Wraps to its two lines whatever height the panel is
                    // being squeezed to, e.g. while it is folded.
                    .fixedSize(horizontal: false, vertical: true)
                    // Shares the row with the countdown now, so it wraps
                    // rather than pushing the clock aside.
                    .frame(maxWidth: 190, alignment: .trailing)

                Button("Connect") {
                    Task { await planner.connectCalendar() }
                }
                .buttonStyle(SoftButtonStyle(compact: true))
            }
        }
    }

    private var meetingSummary: String {
        let count = planner.meetings.filter { !$0.isAllDay }.count
        return count == 0 ? "No meetings today" : "\(count) meeting\(count == 1 ? "" : "s") today"
    }

    // MARK: Footer

    private var footer: some View {
        HStack(spacing: 12) {
            // Confirmation is INLINE, not a `.confirmationDialog`: a sheet
            // attached to a MenuBarExtra popover makes the popover resign key
            // and close, and the pending action is lost with it.
            if pendingClearAll {
                Text("Delete all \(planner.tasks.count) tasks?")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Theme.text)

                Spacer()

                Button("Cancel") { pendingClearAll = false }
                    .buttonStyle(TextLinkStyle())

                Button("Delete") { performClearAll() }
                    .buttonStyle(DestructiveButtonStyle())
            } else {
                // App-level controls on the left, list housekeeping on the
                // right.
                Button {
                    showSettings.toggle()
                } label: {
                    Image(systemName: "gearshape")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(SoftButtonStyle(circular: true, compact: true))
                .help("Settings")
                .popover(isPresented: $showSettings, arrowEdge: .bottom) {
                    settingsPanel
                }

                Button {
                    NSApplication.shared.terminate(nil)
                } label: {
                    // Slate like the links and the gear, not body text.
                    Text("Quit")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(SoftButtonStyle(compact: true))
                .keyboardShortcut("q")

                // Folds the task list away, keeping the countdown box.
                Button {
                    selectedBlockID = nil
                    planner.panelCollapsed.toggle()
                } label: {
                    Image(systemName: planner.panelCollapsed ? "chevron.down" : "chevron.up")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(SoftButtonStyle(circular: true, compact: true))
                .help(planner.panelCollapsed ? "Show the task list" : "Fold up the task list")

                Link(destination: URL(string: "https://quietpomodoro.com/early-access/")!) {
                    Image(systemName: "iphone")
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(SoftButtonStyle(circular: true, compact: true))
                .help("Quiet Pomodoro early access")
                .accessibilityLabel("Quiet Pomodoro early access")

                Spacer()

                // These act on the list, so they go with it rather than
                // being clickable blind.
                if !planner.panelCollapsed {
                    Button("Clear done") { planner.clearCompleted() }
                        .buttonStyle(TextLinkStyle())
                        .disabled(planner.completedCount == 0)

                    Button("Clear all") { pendingClearAll = true }
                        .buttonStyle(TextLinkStyle())
                        .disabled(planner.tasks.isEmpty)
                }
            }
        }
    }

    private func tick(_ taskID: DayTask.ID) {
        let now = Date()
        guard now.timeIntervalSince(lastTickAt) > NSEvent.doubleClickInterval else { return }
        lastTickAt = now
        planner.toggleDone(id: taskID)
    }

    private func performClearAll() {
        pendingClearAll = false
        selectedBlockID = nil
        planner.clearAll()
    }

    private func settingsSwitch(_ title: String, value: Binding<Bool>) -> some View {
        HStack {
            Text(title)
            Spacer()
            Toggle(title, isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.mini)
        }
    }

    private func settingsNumberInput(_ title: String, value: Binding<Int>,
                                     range: ClosedRange<Int>, step: Int = 1,
                                     defaultValue: Int? = nil, savesWhileTyping: Bool = false) -> some View {
        SettingsNumberInput(title: title, value: value, range: range, step: step,
                            defaultValue: defaultValue, savesWhileTyping: savesWhileTyping)
    }

    private func finishMarker(_ time: Date) -> some View {
        Rectangle()
            .fill(Color.red.opacity(0.45))
            .frame(height: 1)
            .padding(.vertical, 8)
            .padding(.horizontal, -18)
            .accessibilityLabel("Finish \(time.formatted(date: .omitted, time: .shortened))")
            .help("Finish \(time.formatted(date: .omitted, time: .shortened))")
    }

    private var settingsPanel: some View {
        VStack(alignment: .leading, spacing: 9) {
            settingsSwitch("Show label in menu bar", value: $planner.showLabelInMenuBar)
            settingsSwitch("Auto-start next block", value: $planner.autoStartNext)
                .help("Roll straight into the next block when one finishes")

            ThemeDivider()

            settingsNumberInput("Work block (min)",
                            value: $planner.workMinutes, range: 5...120)
            settingsNumberInput("Short break (min)",
                            value: $planner.shortBreakMinutes, range: 1...30)
            settingsNumberInput("Long break (min)",
                            value: $planner.longBreakMinutes, range: 1...60)
            settingsNumberInput("Start hour",
                            value: $planner.dayStartHour, range: 0...23)
            settingsNumberInput("Start minute",
                            value: $planner.dayStartMinute, range: 0...55, step: 5)

            ThemeDivider()

            settingsSwitch("Finish time", value: $planner.finishTimeEnabled)
            if planner.finishTimeEnabled {
                // 24-hour, like the times in the timeline: 17 is 5pm. An emptied
                // box goes back to 17:00 rather than staying blank.
                settingsNumberInput("Hour (0-23)",
                                value: $planner.finishHour, range: 0...23,
                                defaultValue: DayPlanner.defaultFinishHour, savesWhileTyping: true)
                settingsNumberInput("Minute",
                                value: $planner.finishMinute, range: 0...59,
                                defaultValue: DayPlanner.defaultFinishMinute, savesWhileTyping: true)
            }

            ThemeDivider()

            CalendarSettings(planner: planner)

            #if !APP_STORE
            // App Store builds are updated by the store, which also rejects
            // apps that offer their own update check.
            ThemeDivider()

            Button("Check for Updates…") { updates.checkForUpdates() }
                .buttonStyle(TextLinkStyle())
            #endif
        }
        .font(.system(size: 13))
        .tint(Theme.accent)
        .padding(16)
        .frame(width: 300)
    }

    private func addTask() {
        let title = newTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, let totalMinutes = newTaskMinutes else { return }
        if let taskID = planner.addTask(title: title, minutes: totalMinutes, priority: newPriority) {
            pendingScrollID = planner.firstBlockID(for: taskID)
        }
        newTitle = ""
    }
}

// MARK: - Timeline row

struct BlockRow: View {
    let block: ScheduledBlock
    let isActive: Bool
    /// The block the countdown is showing, started or not.
    let isCurrent: Bool
    let isRunning: Bool
    let isPast: Bool
    /// False for calendar events, which can't be edited or deleted from here.
    let canEditTask: Bool
    let taskIsDone: Bool
    /// Break rows edit their owning task, whose name differs from the row label.
    let taskTitle: String
    /// The owning task's full estimate — not this block's chunk length — so the
    /// editor shows the whole duration rather than just one pomodoro.
    let taskEstimateMinutes: Int
    let taskPriority: TaskPriority
    /// True when this row has been clicked, which reveals its buttons.
    let isSelected: Bool
    var displayMinutes: Int? = nil
    let onStart: () -> Void
    let onToggleDone: () -> Void
    let onDeleteTask: () -> Void
    let onUpdateTask: (String, Int, TaskPriority) -> Void
    let onSelect: () -> Void

    @State private var isEditing = false
    @State private var draftTitle = ""
    @State private var draftHours = ""
    @State private var draftMinutes = ""
    @State private var draftPriority: TaskPriority = .leastUrgent

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    static func range(_ block: ScheduledBlock) -> String {
        range(block.start, block.end, allDay: block.isAllDay)
    }

    static func range(_ start: Date, _ end: Date, allDay: Bool = false) -> String {
        // An all-day event runs midnight to midnight, which would render as the
        // nonsense "00:00–00:00".
        if allDay { return "All day" }
        return "\(timeFormatter.string(from: start))–\(timeFormatter.string(from: end))"
    }

    var body: some View {
        if isEditing {
            editor
        } else {
            row
        }
    }

    private var row: some View {
        HStack(spacing: 6) {
            // Work rows tick off like a to-do. Breaks and meetings keep the
            // column empty, so every row's times line up.
            Group {
                if block.kind == .work && canEditTask {
                    TaskCheckbox(isDone: taskIsDone, priority: taskPriority, action: onToggleDone)
                } else {
                    Color.clear
                }
            }
            .frame(width: 20, height: 20)

            // Time first, then the task name to its right. The column is sized
            // to the measured width of "18:42–19:07" at 12pt (74.6pt) rather
            // than a round number, so no space is wasted dead ahead of the title.
            Text(Self.range(block))
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(block.isBreak ? Theme.breakText : Theme.secondaryText)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)

            // Edit sits immediately left of the title. The slot is always
            // reserved so the title doesn't shift when it appears.
            Group {
                if canEditTask && isSelected {
                    Button(action: beginEdit) {
                        Image(systemName: "pencil")
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.accent)
                    .help("Edit this task")
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }
            }
            .frame(width: 12, height: 12)

            VStack(alignment: .leading, spacing: 1) {
                // Centred alignment keeps the calendar name level with a title
                // that has wrapped onto several lines.
                HStack(alignment: .center, spacing: 4) {
                    Text(block.title.isEmpty ? "Untitled" : block.title)
                        .font(.system(size: 13, weight: isActive ? .semibold : .regular))
                        // A long name wraps onto extra lines once the row is
                        // selected, so the whole thing can be read.
                        .lineLimit(isSelected ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)
                        .truncationMode(.tail)
                        .strikethrough(block.isDone)
                        // Task titles use the same grey as their duration.
                        .foregroundStyle(block.isBreak ? Theme.breakText : (block.kind == .work || isDim) ? Theme.secondaryText : Theme.text)

                    // Meetings carry the calendar they came from, in brackets.
                    if block.isMeeting, let name = block.calendarName, !name.isEmpty {
                        Text("(\(name))")
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.secondaryText)
                            .lineLimit(1)
                    }
                }

                // The event's description, on its own line under the title.
                if block.isMeeting, let notes = block.notes, !notes.isEmpty {
                    Text(notes.replacingOccurrences(of: "\n", with: "  "))
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .help(notes)
                }
            }

            Spacer(minLength: 8)

            // Delete sits furthest in, so the minutes keep the far-right
            // column. Edit lives beside the title.
            Group {
                if canEditTask && isSelected {
                    Button(action: onDeleteTask) {
                        Image(systemName: "trash")
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.destructive)
                    .help("Delete this task")
                } else {
                    Color.clear.frame(width: 12, height: 12)
                }
            }
            .frame(width: 12, height: 12)

            // Keep durations in the existing right-aligned column.
            Group {
                if block.isMeeting {
                    Color.clear
                } else {
                    Text(DayPlanMenu.durationText(displayMinutes ?? block.minutes))
                        .font(.system(size: 12))
                        .monospacedDigit()
                        .foregroundStyle(block.isBreak ? Theme.breakText : Theme.secondaryText)
                }
            }
            .frame(width: 64, height: 14, alignment: .trailing)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background { rowBackground }
        .contentShape(Rectangle())
        .onContinuousHover { phase in
            // The pointer is the affordance here rather than a glyph: a hand
            // means "this row is clickable".
            switch phase {
            case .active:
                if canEditTask { NSCursor.pointingHand.set() }
            case .ended:
                NSCursor.arrow.set()
            }
        }
        .onDisappear { NSCursor.arrow.set() }
        .onTapGesture { onSelect() }
        .contextMenu {
            if canEditTask {
                Button(taskIsDone ? "Mark task not done" : "Mark task done") {
                    onToggleDone()
                }
                Divider()
                Button("Delete task", role: .destructive) { onDeleteTask() }
            } else {
                Text("Calendar event")
            }
        }
    }

    /// True when the row is finished or already behind us.
    private var isDim: Bool { block.isDone || isPast }

    /// The active block is raised out of the card, like the selected segment
    /// of a control; a clicked row is pressed in.
    @ViewBuilder
    private var rowBackground: some View {
        if isActive {
            // The orange bar in the marker column marks it as well as the
            // lift: a tint alone measured at only ~1.25:1, so "active" was
            // effectively invisible.
            Color.clear
                .raised(cornerRadius: 10, elevation: 0.3, fill: Theme.raised)
        } else if isSelected {
            Color.clear.insetWell(cornerRadius: 10)
        }
    }

    // MARK: Inline editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Task name", text: $draftTitle)
                .font(.system(size: 13))
                .insetField(height: 32)

            HStack(spacing: 10) {
                DurationField(unit: .hours, text: $draftHours)
                DurationField(unit: .minutes, text: $draftMinutes)

                PriorityPicker(selection: $draftPriority)

                Spacer(minLength: 0)

                Button("Cancel") { isEditing = false }
                    .buttonStyle(SoftButtonStyle(compact: true))
                Button("Save") { commitEdit() }
                    .buttonStyle(PrimaryButtonStyle(compact: true))
                    .keyboardShortcut(.defaultAction)
                    .disabled(draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                              || DurationInput.total(hours: draftHours, minutes: draftMinutes) == nil)
            }
        }
        // Return in any of the editor's boxes saves, rather than falling
        // through to the panel's Start button.
        .onSubmit(commitEdit)
        .padding(12)
        .raised(cornerRadius: 14, elevation: 0.3, fill: Theme.raised)
    }

    private func beginEdit() {
        draftTitle = taskTitle
        let hours = taskEstimateMinutes / 60
        let minutes = taskEstimateMinutes % 60
        // A zero shows as an empty box, so its placeholder names the unit.
        draftHours = hours > 0 ? "\(hours)" : ""
        draftMinutes = minutes > 0 ? "\(minutes)" : ""
        draftPriority = taskPriority
        isEditing = true
    }

    private func commitEdit() {
        // Return reaches here even when Save is disabled, so check the same
        // things it does.
        guard !draftTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let minutes = DurationInput.total(hours: draftHours, minutes: draftMinutes)
        else { return }
        onUpdateTask(draftTitle, minutes, draftPriority)
        isEditing = false
    }


}

// MARK: - Done row

/// A ticked-off task, under the plan: struck through, with the time it was
/// finished. Unticking it puts it back in the plan.
struct DoneRow: View {
    let task: DayTask
    let isSelected: Bool
    let onToggleDone: () -> Void
    let onDelete: () -> Void
    let onSelect: () -> Void

    /// Its id in the panel's row selection, apart from any block's.
    static func rowID(_ taskID: DayTask.ID) -> String { "done-\(taskID.uuidString)" }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    var body: some View {
        // The same columns as a block row, so the two line up.
        HStack(spacing: 6) {
            TaskCheckbox(isDone: true, priority: task.priority, action: onToggleDone)
                .frame(width: 20, height: 20)

            Text(task.completedAt.map { Self.timeFormatter.string(from: $0) } ?? "")
                .font(.system(size: 12).monospacedDigit())
                .foregroundStyle(Theme.secondaryText)
                .lineLimit(1)
                .frame(width: 78, alignment: .leading)
                .help("Finished at this time")

            Color.clear.frame(width: 12, height: 12)

            Text(task.title.isEmpty ? "Untitled" : task.title)
                .font(.system(size: 13))
                .lineLimit(isSelected ? nil : 1)
                .fixedSize(horizontal: false, vertical: true)
                .truncationMode(.tail)
                .foregroundStyle(Theme.secondaryText)

            Spacer(minLength: 8)

            Group {
                if isSelected {
                    Button(action: onDelete) {
                        Image(systemName: "trash")
                            .frame(width: 12, height: 12)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(Theme.destructive)
                    .help("Delete this task")
                } else {
                    Color.clear
                }
            }
            .frame(width: 12, height: 12)

            Color.clear.frame(width: 14)

            Text(DayPlanMenu.durationText(task.estimateMinutes))
                .font(.system(size: 12))
                .monospacedDigit()
                .foregroundStyle(Theme.secondaryText)
                .frame(width: 64, height: 14, alignment: .trailing)
        }
        .overlay {
            Rectangle()
                .fill(Theme.secondaryText)
                .frame(height: 1)
                // Leave the 20pt checkbox and its 6pt gap clear.
                .padding(.leading, 26)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 8)
        .background {
            if isSelected { Color.clear.insetWell(cornerRadius: 10) }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
        .contextMenu {
            Button("Mark task not done", action: onToggleDone)
            Divider()
            Button("Delete task", role: .destructive, action: onDelete)
        }
    }
}

/// Commit typed settings on Return or focus loss, so multi-digit values can
/// be entered before applying bounds and rebuilding the schedule.
private struct SettingsNumberInput: View {
    let title: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    let step: Int
    /// What an emptied box goes back to, and what its placeholder shows, so
    /// the field never reads as blank. Without one it keeps its last value.
    let defaultValue: Int?
    let savesWhileTyping: Bool
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack {
            // The placeholder is the value itself, not the title: the title
            // doesn't fit in a 56pt box and was clipped to "Finis".
            TextField(String(defaultValue ?? value), text: $text)
                .multilineTextAlignment(.center)
                .monospacedDigit()
                .insetField(height: 28)
                .frame(width: 56)
                .focused($focused)
                .accessibilityLabel(title)
                .onAppear { text = String(value) }
                .onSubmit { commit() }
                .onChange(of: text) { _, entered in
                    if savesWhileTyping, let number = Int(entered), range.contains(number) {
                        value = number
                    }
                }
                .onChange(of: focused) { _, isFocused in
                    if !isFocused { commit() }
                }
                .onChange(of: value) { _, newValue in
                    if !focused { text = String(newValue) }
                }
            Text(title)
            Spacer(minLength: 0)
        }
    }

    private func commit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let entered = Int(trimmed) ?? (trimmed.isEmpty ? defaultValue : nil) {
            let bounded = min(range.upperBound, max(range.lowerBound, entered))
            value = range.lowerBound + ((bounded - range.lowerBound) / step) * step
        }
        text = String(value)
    }
}
