import AppKit
import StrataMediaProtocol
import StrataTheme

package final class AudioWaveformView: MediaTimelineView {
    package var waveform: AudioWaveform? {
        didSet {
            duration = waveform?.covered ?? 0
            needsDisplay = true
        }
    }

    package override func draw(_ dirtyRect: NSRect) {
        guard let waveform, !waveform.peaks.isEmpty, duration.isFinite, duration > 0,
              bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let path = NSBezierPath(), center = bounds.midY
        let width = bounds.width / Double(waveform.peaks.count)
        for (index, peak) in waveform.peaks.enumerated() {
            let height = max(1, Double(peak) * (bounds.height - 16))
            path.appendRect(NSRect(x: Double(index) * width, y: center - height / 2, width: max(1, width * 0.8), height: height))
        }
        ThemeStyle.accent.setFill(); path.fill()
        NSColor.labelColor.setFill()
        fillPlayhead(width: 1)
    }
}
