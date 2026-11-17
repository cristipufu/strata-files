import Foundation

/// Panes sent Home while their disk ejects, so a failed eject brings back each one nobody has moved since.
final class DiskDepartures {
    private struct Departure {
        weak var pane: Pane?
        let folder: URL
        let revision: Int
    }

    private var departed: [String: [Departure]] = [:]

    /// After `pane` has gone Home from `folder`.
    func record(_ pane: Pane, leaving folder: URL, from volume: URL) {
        departed[VolumeEjector.key(volume), default: []]
            .append(Departure(pane: pane, folder: folder, revision: pane.navigationRevision))
    }

    func returning(from volume: URL) -> [(pane: Pane, folder: URL)] {
        (departed.removeValue(forKey: VolumeEjector.key(volume)) ?? []).compactMap { departure in
            guard let pane = departure.pane, pane.navigationRevision == departure.revision else { return nil }
            return (pane, departure.folder)
        }
    }

    func forget(_ volume: URL) {
        departed[VolumeEjector.key(volume)] = nil
    }
}
