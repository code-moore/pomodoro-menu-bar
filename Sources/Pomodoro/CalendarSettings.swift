import SwiftUI
import AppKit

/// The Settings section for calendars: which ones count towards the day, and
/// where to add one that's missing.
struct CalendarSettings: View {
    @ObservedObject var planner: DayPlanner

    /// A Google account can bring dozens of calendars; past this many rows the
    /// list scrolls instead of stretching the popover.
    private static let rowsBeforeScrolling = 6
    private static let rowHeight: CGFloat = 22

    /// Checked on macOS 26: opens System Settings at Internet Accounts.
    private static let internetAccountsURL =
        URL(string: "x-apple.systempreferences:com.apple.Internet-Accounts-Settings.extension")!

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Calendars")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Theme.secondaryText)

            if planner.calendarAuthorized {
                let calendars = planner.availableCalendars
                if calendars.count > Self.rowsBeforeScrolling {
                    ScrollView { list(calendars) }
                        .frame(height: CGFloat(Self.rowsBeforeScrolling) * Self.rowHeight)
                } else {
                    list(calendars)
                }
            } else {
                Text("Connect your calendar from the panel to choose which ones count.")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // Pomodoro reads the calendars macOS knows about, so a missing one
            // is almost always an account that was never added to the Mac.
            Text("Missing a calendar? Add its account to your Mac.")
                .font(.system(size: 12))
                .foregroundStyle(Theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)

            Button("Open Internet Accounts…") {
                NSWorkspace.shared.open(Self.internetAccountsURL)
            }
            .buttonStyle(TextLinkStyle())
        }
    }

    private func list(_ calendars: [CalendarService.CalendarInfo]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(calendars) { calendar in
                Toggle(isOn: isIncluded(calendar.id)) {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(calendar.color.map { Color(cgColor: $0) } ?? Theme.accent)
                            .frame(width: 8, height: 8)
                        Text(calendar.title.isEmpty ? String(localized: "Untitled") : calendar.title)
                            .lineLimit(1)
                        if !calendar.account.isEmpty {
                            Text(calendar.account)
                                .foregroundStyle(Theme.secondaryText)
                                .lineLimit(1)
                        }
                    }
                }
                .toggleStyle(.checkbox)
                .frame(height: Self.rowHeight - 6)
            }
        }
    }

    private func isIncluded(_ id: String) -> Binding<Bool> {
        Binding(
            get: { !planner.excludedCalendarIDs.contains(id) },
            set: { include in
                if include {
                    planner.excludedCalendarIDs.remove(id)
                } else {
                    planner.excludedCalendarIDs.insert(id)
                }
            }
        )
    }
}
