import Foundation

extension FileCommands {
    package func apply(_ plan: Plan, actionName: String, undo: UndoManager?) async -> PlanExecutor.Outcome {
        await PlanExecutor.apply(plan, actionName: actionName, undo: undo, copies: copies, history: history)
    }
}
