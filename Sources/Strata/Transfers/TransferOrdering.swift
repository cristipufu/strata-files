import Foundation

package nonisolated enum TransferOrder: Int, CaseIterable {
    case next, earlier, later

    package var title: String {
        switch self {
        case .next: String(localized: "Run Next", comment: "Transfers: give a waiting job first priority without interrupting active work")
        case .earlier: String(localized: "Move Up", comment: "Transfers: move a waiting job earlier in the queue")
        case .later: String(localized: "Move Down", comment: "Transfers: move a waiting job later in the queue")
        }
    }
}

/// The insertion index after removing the chosen job. Unrelated rows keep their relative order.
package nonisolated enum TransferOrdering {
    package static func destination(for index: Int, among waiting: [Int], order: TransferOrder) -> Int? {
        guard let position = waiting.firstIndex(of: index) else { return nil }
        switch order {
        case .next: return position > 0 ? 0 : nil
        case .earlier: return position > 0 ? waiting[position - 1] : nil
        case .later: return position + 1 < waiting.count ? waiting[position + 1] : nil
        }
    }
}
