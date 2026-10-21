import SwiftUI
import AppKit

/// The handle owns the drag gesture so row clicks and task controls keep working.
struct TaskReorderModifier: ViewModifier {
    @ObservedObject var planner: DayPlanner
    let taskID: UUID?
    @Binding var draggedTaskID: UUID?
    @State private var isDropTarget = false

    static let pasteboardType = "local.pomodoro.task-order"

    func body(content: Content) -> some View {
        HStack(spacing: 2) {
            if let taskID, taskID != planner.activeTaskID {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.secondaryText)
                    .frame(width: 14, height: 24)
                    .contentShape(Rectangle())
                    .help("Drag to reorder within this priority")
                    .accessibilityLabel("Reorder task within its priority")
                    .onDrag {
                        draggedTaskID = taskID
                        return NSItemProvider(item: taskID.uuidString as NSString,
                                              typeIdentifier: Self.pasteboardType)
                    }
            } else {
                Color.clear.frame(width: 14, height: 24)
            }
            content
        }
        .overlay {
            if isDropTarget {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.accent, lineWidth: 1)
                    .allowsHitTesting(false)
            }
        }
        .onDrop(of: [Self.pasteboardType], delegate: TaskOrderDropDelegate(
            planner: planner, targetID: taskID, draggedTaskID: $draggedTaskID, isDropTarget: $isDropTarget))
    }
}

private struct TaskOrderDropDelegate: DropDelegate {
    let planner: DayPlanner
    let targetID: UUID?
    @Binding var draggedTaskID: UUID?

    @Binding var isDropTarget: Bool

    func dropEntered(info: DropInfo) { isDropTarget = validateDrop(info: info) }
    func dropExited(info: DropInfo) { isDropTarget = false }

    func validateDrop(info: DropInfo) -> Bool {
        guard info.hasItemsConforming(to: [TaskReorderModifier.pasteboardType]),
              let source = draggedTaskID, let targetID else { return false }
        return planner.canReorderTask(source, onto: targetID)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: validateDrop(info: info) ? .move : .forbidden)
    }

    func performDrop(info: DropInfo) -> Bool {
        defer { draggedTaskID = nil; isDropTarget = false }
        guard validateDrop(info: info), let source = draggedTaskID, let targetID else { return false }
        return planner.reorderTask(source, onto: targetID)
    }
}
