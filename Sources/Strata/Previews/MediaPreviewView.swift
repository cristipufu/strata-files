import AppKit
import AVKit
import StrataModel
import StrataMediaProtocol
import StrataTheme; import UniformTypeIdentifiers

package final class MediaPreviewView: PreviewView {
    private let url: URL
    private let type: UTType
    private let playerView = VideoPlayerView()
    package let storyboardView = MediaStoryboardView()
    private let hoverImage = NSImageView()
    private let chapters = NSPopUpButton()
    private let transportBar = NSStackView()
    package let playButton = NSButton()
    package let scrubber = MediaScrubber()
    package let muteButton = NSButton()
    private var storyboardHeight: NSLayoutConstraint!
    private let frameSession: MediaFrameSession
    private let waveformSession: AudioWaveformSession
    package let waveformView = AudioWaveformView()
    private let analyzeButton = NSButton()
    private let waveformProgress = NSProgressIndicator()
    private var timeObserver: Any?
    private var endObserver: NSObjectProtocol?
    private weak var observedPlayer: AVPlayer?
    package private(set) var duration: Double = 0
    package private(set) var playhead: Double = 0
    private var isAudio: Bool { type.conforms(to: .audio) }
    private var navigation = MediaNavigation()
    private var active = false
    private weak var observedWindow: NSWindow?
    private var itemObservation: NSKeyValueObservation?
    private var rateObservation: NSKeyValueObservation?
    private var muteObservation: NSKeyValueObservation?
    private var isSeeking = false
    private var pendingSeekTime: CMTime?
    private var resumeAfterSeek = false; private var lastSeekWasCoarse = false
    private var revision = 0

    package init(url: URL, type: UTType, reader: MediaAnalysisReader) {
        self.url = url; self.type = type
        frameSession = MediaFrameSession(reader: reader)
        waveformSession = AudioWaveformSession(reader: reader)
        super.init(frame: .zero)
        playerView.controlsStyle = .none
        playerView.showsFullScreenToggleButton = false
        playerView.allowsPictureInPicturePlayback = false
        playerView.isHidden = isAudio
        for axis in [NSLayoutConstraint.Orientation.horizontal, .vertical] {
            playerView.setContentCompressionResistancePriority(.defaultLow, for: axis)
            playerView.setContentHuggingPriority(.defaultLow, for: axis)
        }
        chapters.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        configureTransport()
        hoverImage.imageScaling = .scaleProportionallyDown
        hoverImage.isHidden = true
        chapters.isHidden = true; storyboardView.isHidden = true
        chapters.target = self; chapters.action = #selector(chooseChapter)
        for view in [playerView, storyboardView, transportBar, hoverImage, chapters] {
            view.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(view)
        }
        storyboardHeight = storyboardView.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor),
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.bottomAnchor.constraint(equalTo: storyboardView.topAnchor, constant: -4),
            storyboardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8), storyboardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            storyboardView.bottomAnchor.constraint(equalTo: transportBar.topAnchor, constant: -4), storyboardHeight,
            transportBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8), transportBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            transportBar.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6), transportBar.heightAnchor.constraint(equalToConstant: 24),
            hoverImage.centerXAnchor.constraint(equalTo: contentView.centerXAnchor), hoverImage.bottomAnchor.constraint(equalTo: storyboardView.topAnchor, constant: -8),
            hoverImage.widthAnchor.constraint(equalToConstant: 192), hoverImage.heightAnchor.constraint(equalToConstant: 108),
            chapters.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8), chapters.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            chapters.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -16),
        ])
        frameSession.onChange = { [weak self] in self?.updateFrames($0) }
        storyboardView.onInspect = { [weak self] in self?.frameSession.inspect(at: $0) }
        bindTimeline(storyboardView)
        if isAudio { configureAudio() }
    }

    @available(*, unavailable) package required init?(coder: NSCoder) { return nil }

    private func configureTransport() {
        for button in [playButton, muteButton] {
            button.bezelStyle = .accessoryBarAction
            button.isBordered = false
            button.imagePosition = .imageOnly
            button.controlSize = .small
            button.setContentHuggingPriority(.required, for: .horizontal)
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                button.widthAnchor.constraint(equalToConstant: 22),
                button.heightAnchor.constraint(equalToConstant: 22),
            ])
        }
        playButton.target = self; playButton.action = #selector(togglePlay)
        muteButton.target = self; muteButton.action = #selector(toggleMute); playerView.onTogglePlay = { [weak self] in self?.togglePlay() }
        scrubber.isEnabled = false
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        scrubber.heightAnchor.constraint(equalToConstant: 24).isActive = true
        bindTimeline(scrubber)
        // Scrubber fills the transport bar between Play and Mute.
        scrubber.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        scrubber.setContentHuggingPriority(.defaultLow, for: .horizontal)
        transportBar.orientation = .horizontal
        transportBar.alignment = .centerY
        transportBar.distribution = .fill
        transportBar.spacing = 6
        transportBar.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        for control in [playButton, scrubber, muteButton] { transportBar.addArrangedSubview(control) }
        transportBar.isHidden = true
        updateTransportControls()
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let observedWindow { NotificationCenter.default.removeObserver(self, name: NSWindow.willCloseNotification, object: observedWindow) }
        observedWindow = window
        guard let window else { stop(); return }
        NotificationCenter.default.addObserver(self, selector: #selector(windowWillClose(_:)), name: NSWindow.willCloseNotification, object: window)
        if !isHiddenOrHasHiddenAncestor { start() }
    }
    package override func viewDidHide() { super.viewDidHide(); stop() }
    package override func viewDidUnhide() { super.viewDidUnhide(); if window != nil { start() } }

    private func start() {
        guard !active else { return }
        active = true
        let url = url, type = type
        load({
            guard let source = await FileReadSource.opening(url) else { throw PreviewError.unsupported }
            let details = try await source.read { _ in await MediaDetails.read(url, contentType: type) }
            guard let duration = details.basic.duration, duration.isFinite, duration > 0,
                  duration <= MediaFrames.durationLimit else { throw PreviewError.unsupported }
            return (source, details)
        }, apply: { [weak self] source, details in self?.show(source, details: details) })
    }

    private func show(_ source: FileReadSource, details: MediaDetails) {
        guard active, window != nil, let mediaDuration = details.basic.duration,
              mediaDuration.isFinite, mediaDuration > 0, mediaDuration <= MediaFrames.durationLimit else { return }
        removeTimeObserver()
        let player = AVPlayer(url: url)
        duration = mediaDuration
        playhead = 0
        isSeeking = false
        pendingSeekTime = nil
        resumeAfterSeek = false
        playerView.isHidden = isAudio
        if isAudio { waveformView.isHidden = false }
        scrubber.minValue = 0
        scrubber.maxValue = duration
        scrubber.doubleValue = 0
        scrubber.isEnabled = true
        transportBar.isHidden = false
        let revision = revision
        itemObservation = player.currentItem?.observe(\.status, options: [.initial, .new]) { @Sendable [weak self] item, _ in
            let status = item.status
            guard status == .failed || status == .readyToPlay else { return }
            Task { @MainActor [weak self] in
                guard let self, active, self.revision == revision else { return }
                if status == .failed {
                    stop()
                    showMessage(symbol: "play.slash", String(localized: "This media couldn’t be played."))
                } else {
                    performPendingSeek()
                }
            }
        }
        rateObservation = player.observe(\.timeControlStatus, options: [.initial, .new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, active, self.revision == revision else { return }
                updateTransportControls()
            }
        }
        muteObservation = player.observe(\.isMuted, options: [.initial, .new]) { @Sendable [weak self] _, _ in
            Task { @MainActor [weak self] in
                guard let self, active, self.revision == revision else { return }
                updateTransportControls()
            }
        }
        if let item = player.currentItem {
            endObserver = NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { @Sendable [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.active, self.revision == revision, !self.isUserScrubbing else { return }
                    self.resumeAfterSeek = false
                    self.updatePlayhead(self.duration)
                    self.updateTransportControls()
                }
            }
        }
        playerView.player = player
        observedPlayer = player
        updateTransportControls()
        navigation = details.navigation
        chapters.removeAllItems()
        for chapter in navigation.chapters ?? [] { chapters.addItem(withTitle: Self.time(chapter.start) + " · " + chapter.title) }
        chapters.isHidden = navigation.chapters?.isEmpty != false
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.25, preferredTimescale: 600), queue: .main) { @Sendable [weak self] time in
            MainActor.assumeIsolated {
                guard let self, self.active, self.revision == revision,
                      !self.isUserScrubbing, !self.isSeeking, self.pendingSeekTime == nil, !self.resumeAfterSeek,
                      let player = self.playerView.player,
                      player.timeControlStatus == .playing else { return }
                self.updatePlayhead(time.seconds)
            }
        }
        if isAudio {
            waveformSession.prepare(source, type: type.identifier, duration: duration)
        } else {
            frameSession.show(source, type: type.identifier)
            updateFooter()
        }
    }

    private func configureAudio() {
        analyzeButton.bezelStyle = .rounded
        analyzeButton.target = self; analyzeButton.action = #selector(analyzeWaveform)
        waveformProgress.style = .spinning; waveformProgress.controlSize = .small
        for view in [waveformView, analyzeButton, waveformProgress] { view.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            waveformView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 16), waveformView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            waveformView.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 16), waveformView.bottomAnchor.constraint(equalTo: transportBar.topAnchor, constant: -8),
            analyzeButton.centerXAnchor.constraint(equalTo: waveformView.centerXAnchor), analyzeButton.centerYAnchor.constraint(equalTo: waveformView.centerYAnchor),
            waveformProgress.trailingAnchor.constraint(equalTo: analyzeButton.leadingAnchor, constant: -8), waveformProgress.centerYAnchor.constraint(equalTo: analyzeButton.centerYAnchor),
        ])
        waveformSession.onChange = { [weak self] in self?.updateWaveform() }
        bindTimeline(waveformView)
    }

    @objc private func analyzeWaveform() {
        if waveformSession.task == nil { waveformSession.analyze() } else { waveformSession.cancel() }
    }

    private func updateWaveform() {
        guard active else { return }
        let loading = waveformSession.task != nil
        waveformView.waveform = waveformSession.waveform
        analyzeButton.title = loading ? String(localized: "Cancel") : String(localized: "Analyze waveform")
        analyzeButton.isHidden = waveformSession.waveform != nil
        waveformProgress.isHidden = !loading
        if loading { waveformProgress.startAnimation(nil) } else { waveformProgress.stopAnimation(nil) }
        updateFooter()
    }

    private func updateFrames(_ change: MediaFrameSession.Change) {
        guard active else { return }
        if change == .storyboard {
            storyboardView.show(frameSession.frames)
            storyboardView.playhead = playhead
            storyboardView.isHidden = frameSession.frames == nil
            storyboardHeight.constant = frameSession.frames == nil ? 0 : 54
        }
        hoverImage.image = frameSession.hovered.flatMap(MediaStoryboardView.image)
        hoverImage.isHidden = hoverImage.image == nil
        updateFooter()
    }

    private func updateFooter() {
        guard active else { return }
        let progress = playhead > 0 ? Self.time(playhead) + " / " + Self.time(duration) : Self.time(duration)
        if isAudio {
            let loading = waveformSession.task != nil
            let note: String
            if let waveform = waveformSession.waveform {
                note = waveform.isComplete ? String(localized: "Click waveform to seek")
                    : String(localized: "Waveform covers first \(Self.time(waveform.covered))", comment: "Audio preview: only the beginning of a recording has been analyzed; inserted text is a duration")
            } else if loading { note = String(localized: "Analyzing waveform…") }
            else if waveformSession.failed { note = String(localized: "Waveform unavailable") }
            else { note = String(localized: "Analyze waveform") }
            footer.show([progress], note: note)
        } else {
            let caption = frameSession.hovered.map { Self.time($0.actual) } ?? progress
            footer.show([caption], note: frameSession.failed ? String(localized: "Storyboard unavailable") : frameSession.frames == nil
                ? String(localized: "Loading storyboard…") : String(localized: "Hover to inspect · Click to seek"))
        }
    }

    private func updateTransportControls() {
        let playing = (playerView.player?.timeControlStatus == .playing) || ((playerView.player?.rate ?? 0) > 0) || resumeAfterSeek
        let muted = playerView.player?.isMuted == true
        playButton.image = NSImage(systemSymbolName: playing ? "pause.fill" : "play.fill",
            accessibilityDescription: playing ? String(localized: "Pause") : String(localized: "Play", comment: "Media preview: start playback"))
        muteButton.image = NSImage(systemSymbolName: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
            accessibilityDescription: muted ? String(localized: "Unmute", comment: "Media preview: unmute audio")
                : String(localized: "Mute", comment: "Media preview: mute audio"))
    }

    private var timelines: [MediaTimelineView] { [scrubber, storyboardView, waveformView] }
    private var isUserScrubbing: Bool { timelines.contains(where: \.isTracking) }
    private var isUserDragging: Bool { timelines.contains(where: \.isDragging) }

    private func bindTimeline(_ timeline: MediaTimelineView) {
        timeline.onBeginTracking = { [weak self] in self?.beginScrubbing() }
        timeline.onSeek = { [weak self] in self?.seek($0) }
        timeline.onEndTracking = { [weak self] in self?.finishScrubbing() }
    }

    private func updatePlayhead(_ seconds: Double) {
        guard seconds.isFinite, duration.isFinite, duration > 0, duration <= MediaFrames.durationLimit,
              playhead.isFinite, playhead >= 0, playhead <= MediaFrames.durationLimit else { return }
        let clamped = min(duration, max(0, seconds))
        let previousSecond = Int(playhead), wasZero = playhead == 0
        playhead = clamped
        for timeline in timelines { timeline.playhead = clamped }
        if Int(clamped) != previousSecond || (clamped == 0) != wasZero {
            updateFooter()
        }
    }

    @objc package func togglePlay() {
        guard active, let player = playerView.player, duration > 0 else { return }
        if player.timeControlStatus == .playing || player.rate > 0 || resumeAfterSeek {
            resumeAfterSeek = false
            player.pause()
        } else {
            if playhead >= duration - 0.05 { seek(0) }
            if isSeeking || pendingSeekTime != nil {
                resumeAfterSeek = true
                performPendingSeek()
            } else {
                player.play()
            }
        }
        updateTransportControls()
    }

    @objc package func toggleMute() {
        guard active, let player = playerView.player else { return }
        player.isMuted.toggle()
        updateTransportControls()
    }

    private func beginScrubbing() {
        guard active, let player = playerView.player else { return }
        if player.timeControlStatus == .playing || player.rate > 0 {
            resumeAfterSeek = true
            player.pause()
        }
    }

    private func finishScrubbing() {
        guard active else { return }
        if lastSeekWasCoarse, pendingSeekTime == nil {
            pendingSeekTime = Self.seekTime(playhead, duration: duration)
        }
        if pendingSeekTime != nil {
            performPendingSeek()
        } else if !isSeeking, !isUserScrubbing, resumeAfterSeek {
            resumeAfterSeek = false
            if playhead < duration { playerView.player?.play() }
            updateTransportControls()
        }
    }

    @objc private func chooseChapter() {
        guard let chapters = navigation.chapters, chapters.indices.contains(self.chapters.indexOfSelectedItem) else { return }
        seek(chapters[self.chapters.indexOfSelectedItem].start)
    }
    package func seek(_ seconds: Double) {
        guard active, let time = Self.seekTime(seconds, duration: duration) else { return }
        if let player = playerView.player, player.timeControlStatus == .playing || player.rate > 0 {
            resumeAfterSeek = true
            player.pause()
        }
        updatePlayhead(time.seconds)
        pendingSeekTime = time
        performPendingSeek()
    }
    private func performPendingSeek() {
        guard active, !isSeeking, let player = playerView.player,
              player.currentItem?.status == .readyToPlay, let time = pendingSeekTime else { return }
        pendingSeekTime = nil
        isSeeking = true
        let revision = revision
        let coarse = isUserDragging
        lastSeekWasCoarse = coarse
        let tolerance: CMTime = coarse ? CMTime(seconds: 0.1, preferredTimescale: 600) : .zero
        player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, active, self.revision == revision else { return }
                isSeeking = false
                if pendingSeekTime == nil, lastSeekWasCoarse, !isUserScrubbing {
                    pendingSeekTime = Self.seekTime(playhead, duration: duration)
                }
                if pendingSeekTime != nil {
                    performPendingSeek()
                } else if !isUserScrubbing, resumeAfterSeek {
                    resumeAfterSeek = false
                    if playhead < duration { playerView.player?.play() }
                    updateTransportControls()
                }
            }
        }
    }
    nonisolated package static func seekTime(_ seconds: Double, duration: Double) -> CMTime? {
        guard duration.isFinite, duration > 0, duration <= MediaFrames.durationLimit,
              seconds.isFinite, seconds >= 0, seconds <= duration else { return nil }
        return CMTime(seconds: seconds, preferredTimescale: 600)
    }
    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= MediaFrames.durationLimit else { return "" }
        let whole = Int(seconds)
        return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }

    private func removeTimeObserver() {
        if let timeObserver, let player = observedPlayer { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        if let endObserver { NotificationCenter.default.removeObserver(endObserver) }
        endObserver = nil
        observedPlayer = nil
    }

    @objc private func windowWillClose(_ notification: Notification) { stop() }

    @objc package override func stop() {
        revision += 1
        active = false
        playhead = 0
        duration = 0
        isSeeking = false
        pendingSeekTime = nil
        resumeAfterSeek = false
        lastSeekWasCoarse = false
        for timeline in timelines { timeline.cancelTracking(); timeline.playhead = 0 }
        frameSession.stop(); itemObservation = nil; rateObservation = nil; muteObservation = nil
        waveformSession.stop(); waveformProgress.stopAnimation(nil); waveformProgress.isHidden = true
        analyzeButton.isHidden = true; waveformView.waveform = nil
        removeTimeObserver()
        chapters.isHidden = true
        storyboardView.show(nil); storyboardHeight.constant = 0; storyboardView.isHidden = true
        hoverImage.image = nil; hoverImage.isHidden = true
        transportBar.isHidden = true; scrubber.duration = 0; scrubber.isEnabled = false
        playerView.player?.pause(); playerView.player?.replaceCurrentItem(with: nil); playerView.player = nil
        super.stop()
    }
}

/// Shared horizontal timeline geometry and pointer scrubbing for the transport bar, storyboard and waveform.
package class MediaTimelineView: NSView, ColorThemeUpdating {
    package var duration: Double = 0 { didSet { if duration != oldValue { needsDisplay = true } } }
    package var playhead: Double = 0 { didSet { if playhead != oldValue { needsDisplay = true } } }
    package var isEnabled = true {
        didSet {
            guard isEnabled != oldValue else { return }
            if !isEnabled { cancelTracking() }
            needsDisplay = true
        }
    }
    package private(set) var isTracking = false { didSet { if isTracking != oldValue { needsDisplay = true } } }
    package private(set) var isDragging = false
    package var onSeek: ((Double) -> Void)?
    var onBeginTracking: (() -> Void)?
    var onEndTracking: (() -> Void)?

    package var trackRect: NSRect { bounds }

    package func updateColorTheme() { needsDisplay = true }
    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    package override var mouseDownCanMoveWindow: Bool { false }

    package override func viewDidHide() {
        super.viewDidHide()
        endTrackingIfNeeded()
    }

    package override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { endTrackingIfNeeded() }
    }

    package func cancelTracking() {
        isTracking = false
        isDragging = false
    }

    private func endTrackingIfNeeded() {
        guard isTracking else { return }
        cancelTracking()
        onEndTracking?()
    }

    package func time(for event: NSEvent) -> Double? {
        let x = convert(event.locationInWindow, from: nil).x
        let rect = trackRect
        guard isEnabled, duration.isFinite, duration > 0, duration <= MediaFrames.durationLimit,
              rect.width.isFinite, rect.width > 0, rect.minX.isFinite, x.isFinite else { return nil }
        return min(1, max(0, Double((x - rect.minX) / rect.width))) * duration
    }

    package func playheadX(in rect: NSRect) -> CGFloat? {
        guard duration.isFinite, duration > 0, duration <= MediaFrames.durationLimit,
              playhead.isFinite, playhead >= 0, playhead <= duration,
              rect.width.isFinite, rect.width > 0, rect.minX.isFinite else { return nil }
        return rect.minX + rect.width * CGFloat(playhead / duration)
    }

    package func fillPlayhead(width: CGFloat, includeZero: Bool = true) {
        guard width.isFinite, width > 0, includeZero || playhead > 0, let x = playheadX(in: trackRect),
              bounds.width.isFinite, bounds.height.isFinite, bounds.width >= width, bounds.height > 0 else { return }
        let clamped = max(bounds.minX, min(bounds.maxX - width, x - width / 2))
        NSRect(x: clamped, y: 0, width: width, height: bounds.height).fill()
    }

    package override func mouseDown(with event: NSEvent) {
        guard let target = time(for: event) else { return }
        isTracking = true
        isDragging = false
        playhead = target
        onBeginTracking?()
        onSeek?(target)
    }

    package override func mouseDragged(with event: NSEvent) {
        guard isTracking, let target = time(for: event) else { return }
        isDragging = true
        playhead = target
        onSeek?(target)
    }

    package override func mouseUp(with event: NSEvent) {
        guard isTracking else { return }
        let target = time(for: event)
        isTracking = false
        isDragging = false
        if let target, abs(target - playhead) > 0.0005 {
            playhead = target
            onSeek?(target)
        }
        onEndTracking?()
    }
}

package final class MediaScrubber: MediaTimelineView {
    private static let knobRadius: CGFloat = 6
    package var minValue: Double = 0
    package var maxValue: Double {
        get { duration }
        set { duration = newValue }
    }
    package var doubleValue: Double {
        get { playhead }
        set { playhead = newValue }
    }

    package override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: 24)
    }

    package override var trackRect: NSRect {
        bounds.width > Self.knobRadius * 2 ? bounds.insetBy(dx: Self.knobRadius, dy: 0) : bounds
    }

    package override func draw(_ dirtyRect: NSRect) {
        let track = trackRect
        guard track.width.isFinite, bounds.height.isFinite, track.width > 0, bounds.height > 0 else { return }
        let bar = NSRect(x: track.minX, y: bounds.midY - 2, width: track.width, height: 4)
        ThemeStyle.border.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 2, yRadius: 2).fill()
        guard isEnabled, let x = playheadX(in: track) else { return }
        let progress = max(0, min(bar.width, x - bar.minX))
        ThemeStyle.accent.setFill()
        if progress > 0 {
            NSBezierPath(roundedRect: NSRect(x: bar.minX, y: bar.minY, width: progress, height: bar.height),
                         xRadius: 2, yRadius: 2).fill()
        }
        let radius: CGFloat = isTracking ? Self.knobRadius : 5
        let knob = NSRect(x: x - radius, y: bounds.midY - radius, width: radius * 2, height: radius * 2)
        NSBezierPath(ovalIn: knob).fill()
    }
}

package final class VideoPlayerView: AVPlayerView {
    var onTogglePlay: (() -> Void)?
    package override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    package override var mouseDownCanMoveWindow: Bool { false }
    package override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
    }
    package override func mouseDown(with event: NSEvent) {
        onTogglePlay?()
    }
}
