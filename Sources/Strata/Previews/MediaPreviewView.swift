import AppKit
import AVKit
import StrataModel
import UniformTypeIdentifiers

package final class MediaPreviewView: PreviewView {
    private let url: URL
    private let type: UTType
    private let playerView = AVPlayerView()
    private let storyboardView = MediaStoryboardView()
    private let hoverImage = NSImageView()
    private let chapters = NSPopUpButton()
    private let frameSession: MediaFrameSession
    private var navigation = MediaNavigation()
    private var active = false
    private weak var observedWindow: NSWindow?
    private var itemObservation: NSKeyValueObservation?
    private var revision = 0

    package init(url: URL, type: UTType, reader: MediaAnalysisReader) {
        self.url = url; self.type = type
        frameSession = MediaFrameSession(reader: reader)
        super.init(frame: .zero)
        playerView.controlsStyle = .floating
        playerView.showsFullScreenToggleButton = false
        playerView.allowsPictureInPicturePlayback = false
        hoverImage.imageScaling = .scaleProportionallyDown
        hoverImage.isHidden = true
        chapters.isHidden = true; storyboardView.isHidden = true
        chapters.target = self; chapters.action = #selector(chooseChapter)
        for view in [playerView, storyboardView, hoverImage, chapters] { view.translatesAutoresizingMaskIntoConstraints = false; contentView.addSubview(view) }
        NSLayoutConstraint.activate([
            playerView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor), playerView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            playerView.topAnchor.constraint(equalTo: contentView.topAnchor), playerView.bottomAnchor.constraint(equalTo: storyboardView.topAnchor, constant: -4),
            storyboardView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8), storyboardView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -8),
            storyboardView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -8), storyboardView.heightAnchor.constraint(equalToConstant: 54),
            hoverImage.centerXAnchor.constraint(equalTo: contentView.centerXAnchor), hoverImage.bottomAnchor.constraint(equalTo: storyboardView.topAnchor, constant: -8),
            hoverImage.widthAnchor.constraint(equalToConstant: 192), hoverImage.heightAnchor.constraint(equalToConstant: 108),
            chapters.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 8), chapters.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 8),
            chapters.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, constant: -16),
        ])
        frameSession.onChange = { [weak self] in self?.updateFrames($0) }
        storyboardView.onInspect = { [weak self] in self?.frameSession.inspect(at: $0) }
        storyboardView.onSeek = { [weak self] in self?.seek($0) }
    }

    @available(*, unavailable) package required init?(coder: NSCoder) { return nil }

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
            guard let duration = details.basic.duration, duration.isFinite, duration > 0 else { throw PreviewError.unsupported }
            return (source, details)
        }, apply: { [weak self] source, details in self?.show(source, details: details) })
    }

    private func show(_ source: FileReadSource, details: MediaDetails) {
        guard active, window != nil else { return }
        let player = AVPlayer(url: url)
        let revision = revision
        itemObservation = player.currentItem?.observe(\.status, options: [.new]) { [weak self] item, _ in
            guard item.status == .failed else { return }
            Task { @MainActor [weak self] in
                guard let self, active, self.revision == revision else { return }
                stop()
                showMessage(symbol: "play.slash", String(localized: "This media couldn’t be played."))
            }
        }
        playerView.player = player
        navigation = details.navigation
        chapters.removeAllItems()
        for chapter in navigation.chapters ?? [] { chapters.addItem(withTitle: Self.time(chapter.start) + " · " + chapter.title) }
        chapters.isHidden = navigation.chapters?.isEmpty != false
        frameSession.show(source, type: type.identifier)
        footer.show([details.basic.durationText ?? ""], note: String(localized: "Loading storyboard…"))
    }

    private func updateFrames(_ change: MediaFrameSession.Change) {
        guard active else { return }
        if change == .storyboard {
            storyboardView.show(frameSession.frames)
            storyboardView.isHidden = frameSession.frames == nil
        }
        hoverImage.image = frameSession.hovered.flatMap(MediaStoryboardView.image)
        hoverImage.isHidden = hoverImage.image == nil
        let caption = frameSession.hovered.map { Self.time($0.actual) } ?? frameSession.frames.map { Self.time($0.duration) } ?? ""
        footer.show([caption], note: frameSession.failed ? String(localized: "Storyboard unavailable") : frameSession.frames == nil
            ? String(localized: "Loading storyboard…") : String(localized: "Hover to inspect · Click to seek"))
    }

    @objc private func chooseChapter() {
        guard let chapters = navigation.chapters, chapters.indices.contains(self.chapters.indexOfSelectedItem) else { return }
        seek(chapters[self.chapters.indexOfSelectedItem].start)
    }
    private func seek(_ seconds: Double) {
        guard active, seconds.isFinite, seconds >= 0 else { return }
        playerView.player?.seek(to: CMTime(seconds: seconds, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }
    private static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0, seconds <= 1_000_000_000 else { return "" }
        let whole = Int(seconds)
        return String(format: "%d:%02d:%02d", whole / 3600, whole / 60 % 60, whole % 60)
    }

    @objc private func windowWillClose(_ notification: Notification) { stop() }

    @objc package override func stop() {
        revision += 1
        active = false
        frameSession.stop(); itemObservation = nil
        storyboardView.show(nil); hoverImage.image = nil
        playerView.player?.pause(); playerView.player?.replaceCurrentItem(with: nil); playerView.player = nil
        super.stop()
    }
}
