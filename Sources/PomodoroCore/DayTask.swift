import Foundation

/// How soon a task needs doing. More urgent tasks are scheduled first.
public enum TaskPriority: Int, Codable, CaseIterable, Comparable, Hashable, Sendable {
    case urgent = 0
    case lessUrgent = 1
    case leastUrgent = 2

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var name: String {
        switch self {
        case .urgent: return String(localized: "Urgent", comment: "Task priority, shown as a tooltip on its coloured dot.")
        case .lessUrgent: return String(localized: "Less urgent", comment: "Task priority, shown as a tooltip on its coloured dot.")
        case .leastUrgent: return String(localized: "Least urgent", comment: "Task priority, shown as a tooltip on its coloured dot.")
        }
    }
}

/// One task the user wants to get through today, with a time estimate.
public struct DayTask: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    /// Optional short text for the menu bar. Falls back to a truncated title.
    public var shortLabel: String
    public var estimateMinutes: Int
    public var completedAt: Date?
    public var priority: TaskPriority
    /// Work already done on it, from work blocks that ran to the end. Only
    /// what's left is laid out, so a finished block isn't planned again.
    public var completedMinutes: Int
    /// How many of its work blocks have run to the end. The blocks still to
    /// come number on from here, so a new block never reuses a finished one's id.
    public var completedBlocks: Int

    public init(
        id: UUID = UUID(),
        title: String = "",
        shortLabel: String = "",
        estimateMinutes: Int = 25,
        completedAt: Date? = nil,
        priority: TaskPriority = .leastUrgent,
        completedMinutes: Int = 0,
        completedBlocks: Int = 0
    ) {
        self.id = id
        self.title = title
        self.shortLabel = shortLabel
        self.estimateMinutes = estimateMinutes
        self.completedAt = completedAt
        self.priority = priority
        self.completedMinutes = completedMinutes
        self.completedBlocks = completedBlocks
    }

    public var isDone: Bool { completedAt != nil }

    /// The part of the estimate not yet worked.
    public var remainingMinutes: Int { max(0, max(1, estimateMinutes) - completedMinutes) }

    /// Records one of its work blocks running to the end: the minutes count
    /// towards the estimate, and the task is done once they cover it.
    public mutating func creditFinishedBlock(minutes: Int, endedAt: Date) {
        completedMinutes += minutes
        completedBlocks += 1
        if remainingMinutes == 0 { completedAt = endedAt }
    }

    private enum CodingKeys: String, CodingKey {
        case id, title, shortLabel, estimateMinutes, completedAt
        case priority, completedMinutes, completedBlocks
    }

    /// Saved history predates priorities and progress, so those keys may be
    /// missing. Without the defaults a single old task would make the whole
    /// history unreadable.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        shortLabel = try container.decodeIfPresent(String.self, forKey: .shortLabel) ?? ""
        estimateMinutes = try container.decode(Int.self, forKey: .estimateMinutes)
        completedAt = try container.decodeIfPresent(Date.self, forKey: .completedAt)
        priority = (try? container.decodeIfPresent(TaskPriority.self, forKey: .priority)) ?? .leastUrgent
        completedMinutes = try container.decodeIfPresent(Int.self, forKey: .completedMinutes) ?? 0
        completedBlocks = try container.decodeIfPresent(Int.self, forKey: .completedBlocks) ?? 0
    }
}
