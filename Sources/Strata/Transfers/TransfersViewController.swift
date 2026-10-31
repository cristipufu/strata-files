import AppKit

/// The Transfers popover: running jobs, waiting jobs in priority order, then recent finished jobs, with controls.
/// Finished jobs stay until "Clear" is clicked.
package final class TransfersViewController: NSViewController {
    package static let width: CGFloat = 360
    private static let maxListHeight: CGFloat = 440

    /// Called by a row's reveal button. Defaults to revealing in Finder; the browser window should navigate itself.
    package var onReveal: ((any QueueJob) -> Void)?

    private let queue: TransferQueue
    private let listStack = NSStackView()
    private let scrollView = NSScrollView()
    private let emptyView = NSStackView()
    private let clearButton = NSButton(title: String(localized: "Clear", comment: "Transfers popover: remove finished jobs from the list"),
                                       target: nil, action: nil)
    private var rows: [ObjectIdentifier: TransferRowView] = [:]
    private var listHeight: NSLayoutConstraint!

    package init(queue: TransferQueue) {
        self.queue = queue
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override func loadView() {
        let title = NSTextField(labelWithString: TransfersToolbarItem.localizedLabel)
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        clearButton.target = self
        clearButton.action = #selector(clearFinished(_:))
        clearButton.bezelStyle = .push
        clearButton.controlSize = .small
        clearButton.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        clearButton.toolTip = String(localized: "Remove finished transfers from the list")
        let header = NSStackView(views: [title, NSView(), clearButton])
        header.edgeInsets = NSEdgeInsets(top: 10, left: 16, bottom: 8, right: 12)
        header.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 0
        listStack.translatesAutoresizingMaskIntoConstraints = false
        let document = TransfersFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        scrollView.documentView = document
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        let emptyTitle = NSTextField(labelWithString: String(localized: "No Transfers"))
        emptyTitle.font = .systemFont(ofSize: 13, weight: .medium)
        emptyTitle.textColor = .secondaryLabelColor
        let emptyBody = NSTextField(labelWithString: String(localized: "Copies and moves you start appear here."))
        emptyBody.font = .systemFont(ofSize: 11)
        emptyBody.textColor = .tertiaryLabelColor
        emptyView.setViews([emptyTitle, emptyBody], in: .center)
        emptyView.orientation = .vertical
        emptyView.spacing = 3
        emptyView.translatesAutoresizingMaskIntoConstraints = false

        let root = NSView()
        root.addSubview(header)
        root.addSubview(separator)
        root.addSubview(scrollView)
        root.addSubview(emptyView)
        listHeight = scrollView.heightAnchor.constraint(equalToConstant: 96)
        NSLayoutConstraint.activate([
            root.widthAnchor.constraint(equalToConstant: Self.width),
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            separator.topAnchor.constraint(equalTo: header.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: separator.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            listHeight,
            document.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            document.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            document.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor),
            emptyView.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyView.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
        view = root
        NotificationCenter.default.addObserver(self, selector: #selector(queueChanged), name: TransferQueue.didChangeNotification,
                                               object: queue)
        reload()
    }

    @objc private func queueChanged() {
        // Only while on screen; the popover reloads before it opens.
        if view.window != nil { reload() }
    }

    @objc private func clearFinished(_ sender: Any?) {
        queue.clearFinished()
    }

    /// Brings the rows in line with the queue and resizes to fit (up to a scrolling maximum).
    package func reload() {
        guard isViewLoaded else { return }
        let jobs = queue.displayJobs
        let ids = Set(jobs.map(ObjectIdentifier.init))
        for (id, row) in rows where !ids.contains(id) {
            row.removeFromSuperview()
            rows[id] = nil
        }
        var ordered: [TransferRowView] = []
        for job in jobs {
            let row = rows[ObjectIdentifier(job)] ?? makeRow(job)
            row.update()
            ordered.append(row)
        }
        if listStack.arrangedSubviews != ordered {
            listStack.arrangedSubviews.forEach { listStack.removeArrangedSubview($0); $0.removeFromSuperview() }
            for row in ordered {
                listStack.addArrangedSubview(row)
                row.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
            }
        }
        for (index, row) in ordered.enumerated() { row.showsSeparator = index < ordered.count - 1 }
        emptyView.isHidden = !jobs.isEmpty
        clearButton.isEnabled = queue.hasFinishedJobs
        listStack.layoutSubtreeIfNeeded()
        let content = ordered.reduce(0) { $0 + $1.fittingSize.height }
        listHeight.constant = jobs.isEmpty ? 96 : min(Self.maxListHeight, content)
        view.layoutSubtreeIfNeeded()
        preferredContentSize = view.fittingSize
    }

    private func makeRow(_ job: any QueueJob) -> TransferRowView {
        let row = TransferRowView(job: job)
        row.onReveal = { [weak self] job in self?.reveal(job) }
        row.canOrder = { [weak self] job, order in self?.queue.canReorder(job, order) ?? false }
        row.onOrder = { [weak self] job, order in self?.queue.reorder(job, order) }
        rows[ObjectIdentifier(job)] = row
        return row
    }

    private func reveal(_ job: any QueueJob) {
        if let onReveal { return onReveal(job) }
        let existing = job.createdItems.filter { TransferEngine.exists($0) }
        if existing.isEmpty {
            NSWorkspace.shared.open(job.destination)
        } else {
            NSWorkspace.shared.activateFileViewerSelecting(existing)
        }
    }
}

/// One job: icon, title, progress bar, status line, and its buttons.
package final class TransferRowView: NSView, NSMenuItemValidation {
    package let job: any QueueJob
    package var onReveal: ((any QueueJob) -> Void)?
    package var canOrder: ((any QueueJob, TransferOrder) -> Bool)?
    package var onOrder: ((any QueueJob, TransferOrder) -> Void)?
    package var showsSeparator = true {
        didSet { if showsSeparator != oldValue { needsDisplay = true } }
    }

    private let icon = TransferIconView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let statusLabel = NSTextField(labelWithString: "")
    private let progress = NSProgressIndicator()
    private lazy var pauseButton = makeButton("pause.circle.fill", "Pause", #selector(togglePause(_:)))
    private lazy var cancelButton = makeButton("xmark.circle.fill", "Stop", #selector(cancel(_:)))
    private lazy var retryButton = makeButton("arrow.clockwise.circle.fill", "Retry Failed", #selector(retry(_:)))
    private lazy var revealButton = makeButton("magnifyingglass.circle.fill", "Show in Folder", #selector(reveal(_:)))
    private lazy var nextButton = makeButton("arrow.up.circle", "Run Next", #selector(runNext(_:)))

    package init(job: any QueueJob) {
        self.job = job
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.lineBreakMode = .byTruncatingMiddle
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.cell?.truncatesLastVisibleLine = true
        statusLabel.preferredMaxLayoutWidth = 290
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        progress.style = .bar
        progress.controlSize = .small
        progress.minValue = 0
        progress.maxValue = 1
        progress.isIndeterminate = false

        let buttons = NSStackView(views: [nextButton, pauseButton, retryButton, cancelButton, revealButton])
        buttons.spacing = 4
        buttons.setHuggingPriority(.required, for: .horizontal)
        buttons.setContentCompressionResistancePriority(.required, for: .horizontal)

        // Buttons share the title's line so the bar and the status line get the full width.
        let titleRow = NSStackView(views: [titleLabel, buttons])
        titleRow.spacing = 8
        titleRow.alignment = .centerY
        titleRow.distribution = .fill

        let text = NSStackView(views: [titleRow, progress, statusLabel])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 3
        text.setCustomSpacing(5, after: progress)
        text.detachesHiddenViews = true

        for view in [icon, text] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            icon.topAnchor.constraint(equalTo: topAnchor, constant: 11),
            icon.widthAnchor.constraint(equalToConstant: 30),
            icon.heightAnchor.constraint(equalToConstant: 30),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.topAnchor.constraint(equalTo: topAnchor, constant: 9),
            text.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -10),
            text.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            titleRow.widthAnchor.constraint(equalTo: text.widthAnchor),
            titleRow.heightAnchor.constraint(equalToConstant: 20),
            statusLabel.widthAnchor.constraint(lessThanOrEqualTo: text.widthAnchor),
            progress.widthAnchor.constraint(equalTo: text.widthAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 52),
        ])
        update()
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    private func makeButton(_ symbol: String, _ label: String.LocalizationValue, _ action: Selector) -> NSButton {
        let text = String(localized: label)
        let button = NSButton()
        button.isBordered = false
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.toolTip = text
        button.setAccessibilityLabel(text)
        setSymbol(symbol, on: button)
        button.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            button.widthAnchor.constraint(equalToConstant: 20),
            button.heightAnchor.constraint(equalToConstant: 20),
        ])
        return button
    }

    private func setSymbol(_ symbol: String, on button: NSButton) {
        guard button.identifier?.rawValue != symbol else { return }
        button.identifier = NSUserInterfaceItemIdentifier(symbol)
        let configuration = NSImage.SymbolConfiguration(pointSize: 16, weight: .regular)
            .applying(.init(hierarchicalColor: .secondaryLabelColor))
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: button.toolTip)?
            .withSymbolConfiguration(configuration)
    }

    package func update() {
        titleLabel.stringValue = job.title
        titleLabel.toolTip = job.title
        statusLabel.attributedStringValue = statusText()
        statusLabel.toolTip = job.failureSummary

        let state = job.state
        let showsBar = state == .running || state == .paused || state == .scanning
        progress.isHidden = !showsBar
        if showsBar {
            if let fraction = job.fractionCompleted {
                if progress.isIndeterminate {
                    progress.stopAnimation(nil)
                    progress.isIndeterminate = false
                }
                progress.doubleValue = fraction
            } else if !progress.isIndeterminate {
                progress.isIndeterminate = true
                progress.startAnimation(nil)
            }
        }

        icon.symbolName = job.symbolName
        icon.tint = switch state {
        case .finished: job.failureCount == 0 ? .systemGreen : .systemOrange
        case .failed: .systemRed
        case .cancelled: .secondaryLabelColor
        case .paused, .queued: .secondaryLabelColor
        case .scanning, .running: .controlAccentColor
        }

        pauseButton.isHidden = !(job.canPause || job.canResume)
        if job.canResume {
            let resume = String(localized: "Resume", comment: "Transfers list: continue a paused job")
            pauseButton.toolTip = resume
            pauseButton.setAccessibilityLabel(resume)
            setSymbol("play.circle.fill", on: pauseButton)
        } else {
            let pause = String(localized: "Pause", comment: "Transfers list: pause a job")
            pauseButton.toolTip = pause
            pauseButton.setAccessibilityLabel(pause)
            setSymbol("pause.circle.fill", on: pauseButton)
        }
        cancelButton.isHidden = !job.canCancel
        retryButton.isHidden = !job.canRetry
        revealButton.isHidden = state.isActive || (job.createdItems.isEmpty && state != .finished)
        nextButton.isHidden = canOrder?(job, .next) != true
    }

    private func statusText() -> NSAttributedString {
        let text = job.statusText
        // Errors get a second line; everything else stays on one.
        let multiline = job.state == .failed
        statusLabel.maximumNumberOfLines = multiline ? 2 : 1
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = multiline ? .byWordWrapping : .byTruncatingTail
        let base: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor,
                                                   .paragraphStyle: paragraph]
        let result = NSMutableAttributedString(string: text, attributes: base)
        switch job.state {
        case .failed:
            result.addAttribute(.foregroundColor, value: NSColor.systemRed, range: NSRange(location: 0, length: result.length))
        case .finished where job.failureCount > 0:
            let failed = TransferFormat.failed(job.failureCount)
            let range = (text as NSString).range(of: failed)
            if range.location != NSNotFound { result.addAttribute(.foregroundColor, value: NSColor.systemRed, range: range) }
        default:
            break
        }
        return result
    }

    @objc private func togglePause(_ sender: Any?) {
        if job.canResume { job.resume() } else { job.pause() }
    }

    @objc private func cancel(_ sender: Any?) { job.cancel() }
    @objc private func retry(_ sender: Any?) { job.retryFailed() }
    @objc private func reveal(_ sender: Any?) { onReveal?(job) }
    @objc private func runNext(_ sender: Any?) { onOrder?(job, .next) }

    package override func menu(for event: NSEvent) -> NSMenu? {
        guard TransferOrder.allCases.contains(where: { canOrder?(job, $0) == true }) else { return nil }
        let menu = NSMenu()
        for order in TransferOrder.allCases {
            let item = NSMenuItem(title: order.title, action: #selector(orderSelected(_:)), keyEquivalent: "")
            item.tag = order.rawValue; item.target = self
            menu.addItem(item)
        }
        return menu
    }

    package func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        guard let order = TransferOrder(rawValue: menuItem.tag) else { return false }
        return canOrder?(job, order) == true
    }

    @objc private func orderSelected(_ sender: NSMenuItem) {
        guard let order = TransferOrder(rawValue: sender.tag) else { return }
        onOrder?(job, order)
    }

    package override func draw(_ dirtyRect: NSRect) {
        guard showsSeparator else { return }
        NSColor.separatorColor.setFill()
        NSRect(x: 54, y: 0, width: bounds.width - 54, height: 1).fill()
    }

    package override var isFlipped: Bool { false }
}

/// The job's symbol on a softly tinted circle.
package final class TransferIconView: NSView {
    package var symbolName = "doc.on.doc" { didSet { if symbolName != oldValue { needsDisplay = true } } }
    package var tint: NSColor = .controlAccentColor { didSet { if tint != oldValue { needsDisplay = true } } }

    package override func draw(_ dirtyRect: NSRect) {
        tint.withAlphaComponent(0.15).setFill()
        NSBezierPath(ovalIn: bounds).fill()
        let configuration = NSImage.SymbolConfiguration(pointSize: 13, weight: .medium)
            .applying(.init(paletteColors: [tint]))
        guard let image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(configuration) else { return }
        let size = image.size
        image.draw(in: NSRect(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2,
                              width: size.width, height: size.height))
    }
}

private final class TransfersFlippedView: NSView {
    override var isFlipped: Bool { true }
}
