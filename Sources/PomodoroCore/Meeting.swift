import Foundation

/// A calendar event, flattened down to what the scheduler needs.
public struct Meeting: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let start: Date
    public let end: Date
    public let isAllDay: Bool
    /// The calendar the event came from, e.g. "Work" or "Personal".
    public let calendarName: String?
    /// The event's description / notes field, if it has one.
    public let notes: String?

    public init(
        id: String,
        title: String,
        start: Date,
        end: Date,
        isAllDay: Bool = false,
        calendarName: String? = nil,
        notes: String? = nil
    ) {
        self.id = id
        self.title = title
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.calendarName = calendarName
        self.notes = notes
    }
}
