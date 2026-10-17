import AppKit
import Foundation
import EventKit
import PomodoroCore

@MainActor
protocol PlannerCalendar {
    var isAuthorized: Bool { get }
    var statusDescription: String { get }
    var lastError: String? { get }
    func requestAccess() async
    func eventCalendars() -> [CalendarService.CalendarInfo]
    func meetings(on day: Date, excluding excluded: Set<String>) -> [Meeting]
}

/// Reads the user's calendars through EventKit.
///
/// macOS gates calendar access behind TCC. The permission prompt only appears
/// once per code-signing identity, which is why the app is signed with a
/// Developer ID rather than ad-hoc: an ad-hoc signature changes on every build,
/// so macOS would treat each rebuild as a new app and prompt again.
@MainActor
final class CalendarService: PlannerCalendar {
    private let store = EKEventStore()

    private(set) var lastError: String?

    var isAuthorized: Bool {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .fullAccess, .authorized:
            return true
        default:
            return false
        }
    }

    var statusDescription: String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: return "Not connected"
        case .restricted: return "Restricted by system policy"
        case .denied: return "Access denied"
        case .fullAccess, .authorized: return "Connected"
        case .writeOnly: return "Write-only access"
        @unknown default: return "Unknown"
        }
    }

    /// Where macOS lets the user switch calendar access back on.
    private static let privacySettingsURL =
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    func requestAccess() async {
        // An accessory app isn't frontmost, and macOS can park the permission
        // prompt behind everything else.
        NSApplication.shared.activate(ignoringOtherApps: true)

        do {
            let granted = try await store.requestFullAccessToEvents()
            lastError = granted ? nil : Self.deniedMessage(for: EKEventStore.authorizationStatus(for: .event))
        } catch {
            lastError = error.localizedDescription
        }

        // Once macOS has answered "no" it never asks again, so the only way
        // forward is the switch in System Settings. Take the user there.
        if !isAuthorized, EKEventStore.authorizationStatus(for: .event) == .denied {
            NSWorkspace.shared.open(Self.privacySettingsURL)
        }
    }

    /// What to tell the user when the request came back without access. Kept
    /// short: it shares the panel's header with the countdown, in two lines.
    private static func deniedMessage(for status: EKAuthorizationStatus) -> String {
        switch status {
        case .denied: return "Allow Pomodoro in System Settings > Privacy > Calendars"
        case .restricted: return "Calendar access is restricted on this Mac"
        case .writeOnly: return "Choose Full Access for Pomodoro in System Settings"
        default: return "macOS did not grant calendar access, try Connect again"
        }
    }

    /// One calendar, as the Settings list shows it.
    struct CalendarInfo: Identifiable {
        let id: String
        let title: String
        /// The account it belongs to, e.g. "iCloud" or a Google address.
        let account: String
        let color: CGColor?
    }

    /// Every event calendar on the Mac, grouped by account.
    func eventCalendars() -> [CalendarInfo] {
        guard isAuthorized else { return [] }
        return store.calendars(for: .event)
            .map { calendar in
                CalendarInfo(
                    id: calendar.calendarIdentifier,
                    title: calendar.title.trimmingCharacters(in: .whitespacesAndNewlines),
                    account: calendar.source?.title ?? "",
                    color: calendar.cgColor
                )
            }
            .sorted { ($0.account, $0.title) < ($1.account, $1.title) }
    }

    /// Today's events, flattened for the scheduler, from every calendar except
    /// the ones switched off in Settings.
    func meetings(on day: Date, excluding excluded: Set<String> = []) -> [Meeting] {
        guard isAuthorized else { return [] }

        let calendar = Calendar.current
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }

        let included = store.calendars(for: .event)
            .filter { !excluded.contains($0.calendarIdentifier) }
        // Checked here rather than passed on: whether EventKit reads an empty
        // list as "none" or "no filter" isn't something to rely on.
        guard !included.isEmpty else { return [] }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: included)

        return store.events(matching: predicate)
            .filter { $0.status != .canceled && !Self.isDeclined($0) }
            .map { event in
                // Calendar names often arrive with padding ("General ").
                let calendarName = event.calendar?.title
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let title = event.title?.trimmingCharacters(in: .whitespacesAndNewlines)
                let notes = event.notes?.trimmingCharacters(in: .whitespacesAndNewlines)

                return Meeting(
                    id: Self.stableID(for: event),
                    title: (title?.isEmpty == false) ? title! : "Untitled event",
                    start: event.startDate,
                    end: event.endDate,
                    isAllDay: event.isAllDay,
                    calendarName: (calendarName?.isEmpty == false) ? calendarName : nil,
                    notes: (notes?.isEmpty == false) ? notes : nil
                )
            }
            .sorted { $0.start < $1.start }
    }

    /// True when the user turned the invite down. EventKit still returns those
    /// events, and counting them as busy pushed work back for meetings the user
    /// isn't going to.
    private static func isDeclined(_ event: EKEvent) -> Bool {
        event.attendees?.contains { $0.isCurrentUser && $0.participantStatus == .declined } ?? false
    }

    /// A deterministic identity for an event.
    ///
    /// Falling back to `UUID()` gave the same event a different id on every
    /// refresh, so its timeline block was treated as brand new each time — the
    /// row flickered and any countdown running on it was cancelled. Deriving
    /// the fallback from the event's own content keeps it stable.
    private static func stableID(for event: EKEvent) -> String {
        if let identifier = event.eventIdentifier, !identifier.isEmpty {
            return identifier
        }
        let start = event.startDate?.timeIntervalSince1970 ?? 0
        let end = event.endDate?.timeIntervalSince1970 ?? 0
        return "\(event.title ?? "")|\(start)|\(end)|\(event.calendar?.calendarIdentifier ?? "")"
    }
}
