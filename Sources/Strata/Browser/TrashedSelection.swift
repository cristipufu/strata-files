import Foundation

/// What a pane selects once Move to Trash has taken its items (`removed`, by the paths they were listed under, never
/// asked of the disk: a standardized path changes once its item has gone): the row that slides into the first removed
/// one's place, unless another place or selection was chosen meanwhile.
enum TrashedSelection {
    /// The row that takes the first removed row's place in `rows`, or the last one left; nil when nothing's left.
    static func next(after removed: Set<String>, in rows: [URL]) -> URL? {
        let survivors = rows.filter { !removed.contains($0.path) }
        return rows.firstIndex(where: { removed.contains($0.path) }).flatMap { first in
            survivors.isEmpty ? nil : survivors[min(first, survivors.count - 1)]
        }
    }

    /// Whether `selection` is still the one Move to Trash was asked with: only those items, or none once they've left
    /// the list.
    static func stillTrashed(_ selection: [URL], _ removed: Set<String>, listed: [URL]) -> Bool {
        guard selection.allSatisfy({ removed.contains($0.path) }) else { return false }
        return !selection.isEmpty || !listed.contains { removed.contains($0.path) }
    }
}
