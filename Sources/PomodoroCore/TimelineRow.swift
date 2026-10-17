import Foundation

/// A collapsed task keeps its scheduled range, but counts only its work and
/// breaks in the duration (calendar events and gaps are not task time).
public struct TimelineRow: Identifiable {
    public let block: ScheduledBlock
    public let minutes: Int
    public let blockIDs: Set<String>
    public var id: String { block.id }

    /// Keep the cutoff before the whole task that cannot fit, even when its
    /// sessions are expanded. All-day calendar banners do not consume time.
    public static func finishIndex(in rows: [TimelineRow], at finish: Date) -> Int? {
        let taskEnds = Dictionary(grouping: rows.filter { $0.block.taskID != nil },
                                  by: { $0.block.taskID! })
            .mapValues { $0.map { $0.block.end }.max()! }
        return rows.firstIndex { row in
            guard !row.block.isAllDay else { return false }
            let end = row.block.taskID.flatMap { taskEnds[$0] } ?? row.block.end
            return row.block.start >= finish || end > finish
        }
    }

    public static func make(blocks: [ScheduledBlock], expandedTaskID: UUID?) -> [TimelineRow] {
        let grouped = Dictionary(grouping: blocks.filter { $0.taskID != nil }, by: { $0.taskID! })
        var seen = Set<UUID>()
        return blocks.compactMap { block in
            guard let taskID = block.taskID, taskID != expandedTaskID else {
                return TimelineRow(block: block, minutes: block.minutes, blockIDs: [block.id])
            }
            guard seen.insert(taskID).inserted, let taskBlocks = grouped[taskID],
                  let work = taskBlocks.first(where: { $0.kind == .work }) else { return nil }
            let summary = ScheduledBlock(
                id: work.id, kind: .work, title: work.title,
                start: taskBlocks.map(\.start).min()!, end: taskBlocks.map(\.end).max()!,
                taskID: taskID, isDone: work.isDone
            )
            return TimelineRow(block: summary, minutes: taskBlocks.reduce(0) { $0 + $1.minutes },
                               blockIDs: Set(taskBlocks.map(\.id)))
        }
    }
}
