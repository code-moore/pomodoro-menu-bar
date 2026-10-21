import XCTest
import AppKit
import SwiftUI
import PomodoroCore
@testable import Pomodoro

/// Native layout smoke coverage, using synthetic calendar text and no real calendar.
final class CalendarRowLayoutTests: XCTestCase {
    @MainActor func testLongCalendarContentFitsPanelAndExpandsVertically() throws {
        let start = Date(timeIntervalSince1970: 1_792_516_800)
        let meeting = ScheduledBlock(id: "layout-meeting", kind: .meeting,
            title: "Product review with a long but meaningful calendar invitation title",
            start: start, end: start.addingTimeInterval(1800), taskID: nil, isDone: false,
            calendarName: "averylongcalendaraddress.withseveralparts@example-calendar.test",
            notes: "Agenda\nReview the new calendar meeting details.\nJoin: https://example.test/meet/abcdefghijklmnopqrstuvwxyz0123456789\nBring notes & questions.")
        let collapsed = try render(meeting, selected: false, name: "meeting-collapsed")
        let expanded = try render(meeting, selected: true, name: "meeting-expanded")
        XCTAssertLessThanOrEqual(collapsed.height, 40, "Collapsed meetings remain a single row")
        XCTAssertGreaterThan(expanded.height, collapsed.height + 50)
        let task = ScheduledBlock(id: "layout-task", kind: .work, title: "Existing task controls",
            start: start, end: start.addingTimeInterval(1500), taskID: UUID(), isDone: false)
        let taskSize = try render(task, selected: true, name: "task-selected")
        XCTAssertLessThanOrEqual(taskSize.height, 40)
    }

    @MainActor private func render(_ block: ScheduledBlock, selected: Bool, name: String) throws -> CGSize {
        _ = NSApplication.shared
        let row = BlockRow(block: block, isActive: false, isCurrent: false, isRunning: false,
            isPast: false, canEditTask: block.taskID != nil, taskIsDone: false, taskTitle: block.title,
            taskEstimateMinutes: 25, taskPriority: .leastUrgent, isSelected: selected,
            onToggleDone: {}, onDeleteTask: {}, onUpdateTask: { _, _, _ in }, onSelect: {})
            .frame(width: 500).padding(10).background(Color.white).environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: row)
        let size = host.fittingSize
        XCTAssertEqual(size.width, 520, accuracy: 1)
        XCTAssertTrue(size.height.isFinite)
        host.frame = CGRect(origin: .zero, size: size)
        host.layoutSubtreeIfNeeded()
        let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/pomodoro-\(name).png"))
        return CGSize(width: size.width - 20, height: size.height - 20)
    }
}
