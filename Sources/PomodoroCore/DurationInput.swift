import Foundation

/// Reads what was typed into an Hours or Minutes box.
///
/// Text is read as typed and either understood or rejected, never quietly
/// rewritten: dropping the "." from "1.5" hours used to turn it into 15 hours.
public enum DurationInput {
    public enum Unit: Sendable {
        case hours
        case minutes
    }

    /// One box's text in minutes, or nil if it isn't a number. Hours may be
    /// fractional ("1.5" or "1,5" is 90 minutes); minutes are whole.
    public static func minutes(in text: String, unit: Unit) -> Int? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch unit {
        case .minutes:
            guard let minutes = Int(trimmed), minutes >= 0 else { return nil }
            return minutes
        case .hours:
            // Digits and at most one separator. `Double()` alone would also
            // accept "1e3", "inf" and "nan".
            let normalised = trimmed.replacingOccurrences(of: ",", with: ".")
            guard normalised.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }),
                  normalised.filter({ $0 == "." }).count <= 1,
                  let hours = Double(normalised) else { return nil }
            return Int(exactly: (hours * 60).rounded())
        }
    }

    /// The two boxes as a total, or nil when either isn't a number or they add
    /// up to no time at all. An empty box counts as zero.
    public static func total(hours: String, minutes: String) -> Int? {
        let fromHours = isBlank(hours) ? 0 : Self.minutes(in: hours, unit: .hours)
        let fromMinutes = isBlank(minutes) ? 0 : Self.minutes(in: minutes, unit: .minutes)
        guard let fromHours, let fromMinutes else { return nil }
        let (total, overflow) = fromHours.addingReportingOverflow(fromMinutes)
        return !overflow && total > 0 ? total : nil
    }

    public static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
