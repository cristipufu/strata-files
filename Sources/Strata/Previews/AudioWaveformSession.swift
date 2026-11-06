import Foundation
import StrataMediaProtocol
import StrataModel

@MainActor package final class AudioWaveformSession {
    private let reader: MediaAnalysisReader
    private var source: FileReadSource?
    private var type = ""
    private var revision = 0
    package private(set) var task: Task<Void, Never>?
    package private(set) var waveform: AudioWaveform?
    package private(set) var failed = false
    package var onChange: (() -> Void)?

    package init(reader: MediaAnalysisReader) { self.reader = reader }
    isolated deinit { task?.cancel() }

    package func prepare(_ source: FileReadSource, type: String, duration: Double) {
        let expected = revision + 1
        stop()
        guard revision == expected else { return }
        self.source = source; self.type = type
        if duration.isFinite, duration > 0, duration <= AudioWaveform.automaticDurationLimit { analyze() }
        else { onChange?() }
    }

    package func analyze() {
        guard task == nil, let source else { return }
        revision += 1
        let revision = revision, reader = reader, type = type
        failed = false
        task = Task { [weak self] in
            let result = try? await reader.waveform(source, type: type)
            guard let self, !Task.isCancelled, self.revision == revision else { return }
            task = nil; waveform = result; failed = result == nil
            onChange?()
        }
        onChange?()
    }

    package func cancel() {
        revision += 1
        let previous = task
        task = nil
        previous?.cancel()
        onChange?()
    }

    package func stop() {
        revision += 1
        let previous = task
        task = nil; source = nil; waveform = nil; failed = false
        previous?.cancel()
    }
}
