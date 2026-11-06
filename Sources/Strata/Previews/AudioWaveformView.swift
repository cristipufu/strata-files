import AppKit
import StrataMediaProtocol
import StrataTheme

package final class AudioWaveformView: NSView, ColorThemeUpdating {
    package var waveform: AudioWaveform? { didSet { needsDisplay = true } }
    package var playhead: Double = 0 { didSet { needsDisplay = true } }
    package var onSeek: ((Double) -> Void)?
    package func updateColorTheme() { needsDisplay = true }

    package override func draw(_ dirtyRect: NSRect) {
        guard let waveform, bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let path = NSBezierPath(), center = bounds.midY
        let width = bounds.width / Double(waveform.peaks.count)
        for (index, peak) in waveform.peaks.enumerated() {
            let height = max(1, Double(peak) * (bounds.height - 16))
            path.appendRect(NSRect(x: Double(index) * width, y: center - height / 2, width: max(1, width * 0.8), height: height))
        }
        ThemeStyle.accent.setFill(); path.fill()
        if playhead.isFinite, playhead >= 0, playhead <= waveform.covered {
            let position = bounds.width * playhead / waveform.covered
            NSColor.labelColor.setFill()
            NSRect(x: position, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    package override func mouseDown(with event: NSEvent) {
        let x = convert(event.locationInWindow, from: nil).x
        guard let waveform, x.isFinite, bounds.width.isFinite, bounds.width > 0 else { return }
        onSeek?(max(0, min(1, x / bounds.width)) * waveform.covered)
    }
}
