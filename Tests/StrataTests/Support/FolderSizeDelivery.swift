import Foundation
@testable import StrataModel

/// Holds what a `FolderSizer` has measured until the test hands it on, so a test waits for a size by a signal and
/// decides itself when it lands.
@MainActor final class FolderSizeDelivery {
    var actions: [@MainActor @Sendable () -> Void] = []
    private var waiting: CheckedContinuation<Void, Never>?

    var callback: FolderSizer.Delivery {
        { [self] action in Task { @MainActor in
            actions.append(action)
            waiting?.resume(); waiting = nil
        } }
    }

    func waitForAction() async {
        if !actions.isEmpty { return }
        await withCheckedContinuation { waiting = $0 }
    }

    func take() async -> @MainActor @Sendable () -> Void {
        await waitForAction()
        return actions.removeFirst()
    }
}
