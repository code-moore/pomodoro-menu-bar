import XCTest
@testable import PomodoroCore

final class TimelineRowTests: XCTestCase {
    func testFinishStaysBeforeOverflowingTaskWhenExpandedOrTaskAdded() {
        let start = Date(timeIntervalSince1970: 0)
        let finish = start.addingTimeInterval(65 * 60)
        let first = DayTask(title: "Fits", estimateMinutes: 25)
        let overflow = DayTask(title: "Does not fit", estimateMinutes: 50)
        let added = DayTask(title: "New task", estimateMinutes: 25, priority: .urgent)
        for tasks in [[first, overflow], [first, overflow, added]] {
            let blocks = Scheduler.buildDay(tasks: tasks, meetings: [], dayStart: start)
            for expanded in [nil, overflow.id] {
                let rows = TimelineRow.make(blocks: blocks, expandedTaskID: expanded)
                let index = TimelineRow.finishIndex(in: rows, at: finish)
                XCTAssertNotNil(index)
                XCTAssertEqual(rows[index!].block.taskID, overflow.id)
                XCTAssertEqual(rows[index!].id, blocks.first { $0.taskID == overflow.id }?.id)
            }
        }
    }

    func testFinishAtExactEndAndAfterAllTasks() {
        let start = Date(timeIntervalSince1970: 0)
        let task = DayTask(title: "Fits", estimateMinutes: 25)
        let blocks = Scheduler.buildDay(tasks: [task], meetings: [], dayStart: start)
        let rows = TimelineRow.make(blocks: blocks, expandedTaskID: nil)
        XCTAssertNil(TimelineRow.finishIndex(in: rows, at: start.addingTimeInterval(30 * 60)))
        XCTAssertNil(TimelineRow.finishIndex(in: rows, at: start.addingTimeInterval(60 * 60)))
        XCTAssertEqual(TimelineRow.finishIndex(in: rows, at: start), 0)
        XCTAssertEqual(TimelineRow.finishIndex(in: rows, at: start.addingTimeInterval(29 * 60)), 0)
    }

    func testCollapsedTaskIncludesShortAndLongBreaks() {
        let task = DayTask(title: "Focus", estimateMinutes: 100)
        let blocks = Scheduler.buildDay(tasks: [task], meetings: [], dayStart: Date(timeIntervalSince1970: 0))
        let rows = TimelineRow.make(blocks: blocks, expandedTaskID: nil)
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.minutes, 130)
        XCTAssertEqual(rows.first?.block.end, blocks.last?.end)
        XCTAssertEqual(rows.first?.blockIDs, Set(blocks.map(\.id)))
        let expanded = TimelineRow.make(blocks: blocks, expandedTaskID: task.id)
        XCTAssertEqual(expanded.map(\.block), blocks)
        XCTAssertEqual(expanded.filter { $0.block.isBreak }.count, 4)
    }

    func testCalendarTimeIsNotIncludedAndOtherTasksStayCollapsed() {
        let first = DayTask(title: "First", estimateMinutes: 50)
        let second = DayTask(title: "Second", estimateMinutes: 50)
        let start = Date(timeIntervalSince1970: 0)
        var blocks = Scheduler.buildDay(tasks: [first, second], meetings: [], dayStart: start)
        blocks.append(ScheduledBlock(id: "meeting", kind: .meeting, title: "Meeting",
                                     start: start, end: start.addingTimeInterval(3600),
                                     taskID: nil, isDone: false))
        let rows = TimelineRow.make(blocks: blocks, expandedTaskID: first.id)
        XCTAssertEqual(rows.filter { $0.block.taskID == first.id }.count, 4)
        XCTAssertEqual(rows.filter { $0.block.taskID == second.id }.count, 1)
        XCTAssertEqual(rows.first { $0.block.taskID == second.id }?.minutes, 70)
        XCTAssertEqual(rows.last?.block.id, "meeting")
    }
}
