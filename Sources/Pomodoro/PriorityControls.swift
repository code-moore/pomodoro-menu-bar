import SwiftUI
import PomodoroCore

extension Theme {
    /// Red, orange and yellow, most urgent first. Darker in Light mode so a
    /// thin outline still shows up on pale glass.
    static func priority(_ level: TaskPriority) -> Color {
        switch level {
        case .urgent: return Color.dynamic(light: 0xD1372A, dark: 0xFF6B5B)
        case .lessUrgent: return Color.dynamic(light: 0xD9730D, dark: 0xF5A04A)
        case .leastUrgent: return Color.dynamic(light: 0xC29A00, dark: 0xF4D03F)
        }
    }

    /// A tick drawn on a filled priority colour. Yellow is too pale for white.
    static func onPriority(_ level: TaskPriority) -> Color {
        level == .leastUrgent ? Color.black.opacity(0.75) : Color.white
    }
}

/// Three outlined circles, red, orange and yellow, for how urgent a task is.
/// The picked one fills in. One is always picked.
struct PriorityPicker: View {
    @Binding var selection: TaskPriority

    var body: some View {
        HStack(spacing: 2) {
            ForEach(TaskPriority.allCases, id: \.self) { level in
                Button {
                    selection = level
                } label: {
                    let colour = Theme.priority(level)
                    Circle()
                        .fill(selection == level ? colour : Color.clear)
                        .overlay(Circle().strokeBorder(colour, lineWidth: 2))
                        .frame(width: 16, height: 16)
                        // A bigger target than the circle itself.
                        .frame(width: 24, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(level.name)
                .accessibilityLabel(level.name)
                .accessibilityAddTraits(selection == level ? .isSelected : [])
            }
        }
    }
}

/// A task's tick box, outlined in its priority colour and green once done.
struct TaskCheckbox: View {
    let isDone: Bool
    let priority: TaskPriority
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            let colour = isDone ? Color.dynamic(light: 0x218543, dark: 0x62D984) : Theme.priority(priority)
            RoundedRectangle(cornerRadius: 4, style: .continuous)
                .fill(isDone ? colour.opacity(0.18) : Color.clear)
                .overlay(
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .strokeBorder(colour, lineWidth: 1.5)
                )
                .overlay {
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .heavy))
                            .foregroundStyle(colour)
                    }
                }
                .frame(width: 14, height: 14)
                .frame(width: 20, height: 20)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(isDone ? "Mark not done" : "Mark done")
        .accessibilityLabel(isDone ? "Mark not done" : "Mark done")
    }
}
