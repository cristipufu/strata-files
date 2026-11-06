import Foundation
import StrataMediaProtocol
import StrataModel

@MainActor package final class MediaFrameSession {
    package enum Change { case storyboard, hover }
    private let reader: MediaAnalysisReader
    private var revision = 0
    private var source: FileReadSource?
    private var type = ""
    private var storyboard: Task<Void, Never>?
    private var hover: Task<Void, Never>?
    private var hoverRevision = 0
    package private(set) var frames: MediaFrames?
    package private(set) var hovered: MediaFrame?
    package private(set) var failed = false
    package var onChange: ((Change) -> Void)?
    package var task: Task<Void, Never>? { storyboard }
    package var hoverTask: Task<Void, Never>? { hover }

    package init(reader: MediaAnalysisReader) { self.reader = reader }
    isolated deinit { storyboard?.cancel(); hover?.cancel() }

    package func show(_ source: FileReadSource, type: String) {
        let expected = revision + 1
        stop()
        guard revision == expected else { return }
        self.source = source; self.type = type
        let revision = revision, reader = reader
        storyboard = Task { [weak self] in
            let result = try? await reader.frames(source, type: type)
            guard let self, !Task.isCancelled, self.revision == revision else { return }
            storyboard = nil; frames = result; failed = result == nil
            onChange?(.storyboard)
        }
    }

    package func inspect(at time: Double?) {
        hoverRevision += 1
        let previous = hover
        hover = nil; hovered = nil
        let revision = revision, hoverRevision = hoverRevision
        if let time, time.isFinite, let source, let frames, time >= 0, time <= frames.duration {
            let reader = reader, type = type
            hover = Task { [weak self] in
                do {
                    try await Task.sleep(for: .milliseconds(150))
                    let result = try await reader.frames(source, type: type, time: time)
                    guard let self, !Task.isCancelled, self.revision == revision, self.hoverRevision == hoverRevision else { return }
                    hover = nil; hovered = result.frames.first
                    onChange?(.hover)
                } catch {
                    guard let self, self.revision == revision, self.hoverRevision == hoverRevision else { return }
                    hover = nil
                }
            }
        }
        previous?.cancel()
        onChange?(.hover)
    }

    package func stop() {
        revision += 1; hoverRevision += 1
        let old = storyboard, oldHover = hover
        storyboard = nil; hover = nil; source = nil; frames = nil; hovered = nil; failed = false
        old?.cancel(); oldHover?.cancel()
    }
}
