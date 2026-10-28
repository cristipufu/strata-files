import AppKit

/// Check for Updates… on apps: a row per app, filled in as each check answers, with what to do next (open the App
/// Store, Software Update, or the app, which installs its own updates).
final class AppUpdatesController: NSViewController {
    private let urls: [URL]
    private var apps: [InstalledApp?]
    private var rows: [AppUpdateRow] = []
    private var results: [AppUpdateResult?]
    private let summary = NSTextField(labelWithString: "")
    private var task: Task<Void, Never>?
    /// Feeds read at once: a few in parallel, not a request per app all together.
    private static let parallelChecks = 4
    private static let rowHeight: CGFloat = 56

    init(urls: [URL]) {
        self.urls = urls
        apps = Array(repeating: nil, count: urls.count)
        results = Array(repeating: nil, count: urls.count)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Whether `url` is the Strata that's running, which its own updater installs.
    static func isThisCopyOfStrata(_ url: URL) -> Bool {
        url.resolvingSymlinksInPath().standardizedFileURL == Bundle.main.bundleURL.resolvingSymlinksInPath().standardizedFileURL
    }

    override func loadView() {
        let title = NSTextField(labelWithString: String(localized: "App Updates", comment: "Title of the sheet that checks the selected apps for updates"))
        title.font = .systemFont(ofSize: 15, weight: .semibold)
        summary.font = .systemFont(ofSize: 12)
        summary.textColor = .secondaryLabelColor
        summary.lineBreakMode = .byTruncatingTail

        let list = NSStackView()
        list.orientation = .vertical
        list.alignment = .leading
        list.spacing = 0
        list.translatesAutoresizingMaskIntoConstraints = false
        for (index, url) in urls.enumerated() {
            if index > 0 {
                let line = NSBox()
                line.boxType = .separator
                list.addArrangedSubview(line)
                line.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            }
            let row = AppUpdateRow(url)
            rows.append(row)
            list.addArrangedSubview(row)
            row.widthAnchor.constraint(equalTo: list.widthAnchor).isActive = true
            row.heightAnchor.constraint(equalToConstant: Self.rowHeight).isActive = true
        }
        let document = FlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(list)
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.documentView = document
        scroll.translatesAutoresizingMaskIntoConstraints = false

        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(close(_:)))
        done.keyEquivalent = "\r"
        // Escape closes the sheet too. A hidden button gets no key equivalents, so this one is there but invisible.
        let escape = NSButton(frame: .zero)
        escape.isTransparent = true
        escape.refusesFirstResponder = true
        escape.setAccessibilityElement(false)
        escape.target = self
        escape.action = #selector(close(_:))
        escape.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spacer, done])

        let stack = NSStackView(views: [title, summary, scroll, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 4
        stack.setCustomSpacing(12, after: summary)
        stack.setCustomSpacing(16, after: scroll)
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView()
        container.addSubview(stack)
        container.addSubview(escape)
        let separators = CGFloat(max(0, urls.count - 1))
        let height = min(CGFloat(urls.count) * Self.rowHeight + separators, 6.5 * Self.rowHeight)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            container.widthAnchor.constraint(equalToConstant: 520),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scroll.heightAnchor.constraint(equalToConstant: height),
            footer.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            summary.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor, constant: -40),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            list.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            list.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            list.topAnchor.constraint(equalTo: document.topAnchor),
            list.bottomAnchor.constraint(equalTo: document.bottomAnchor),
        ])
        view = container
        updateSummary()
    }

    /// Starts once, the first time the sheet shows (hiding the window and showing it again doesn't restart or stop it).
    override func viewDidAppear() {
        super.viewDidAppear()
        guard task == nil else { return }
        let urls = urls
        task = Task { [weak self] in
            // The bundles are read off the main thread; the App Store is asked about all its apps at once.
            let apps = await AppUpdateCheck.read(urls)
            self?.showDetails(apps)
            let store = await AppUpdateCheck.lookUpAppStore(apps)
            await withTaskGroup(of: (Int, AppUpdateResult).self) { group in
                var next = 0
                func startNext() {
                    guard next < apps.count else { return }
                    let index = next, app = apps[index]
                    group.addTask { (index, await AppUpdateCheck.check(app, store: store)) }
                    next += 1
                }
                for _ in 0..<Self.parallelChecks { startNext() }
                for await (index, result) in group {
                    guard let self, !Task.isCancelled else {
                        group.cancelAll()
                        return
                    }
                    self.show(result, at: index)
                    startNext()
                }
            }
        }
    }

    private func showDetails(_ apps: [InstalledApp]) {
        self.apps = apps
        for (row, app) in zip(rows, apps) { row.showDetails(app) }
    }

    private func show(_ result: AppUpdateResult, at index: Int) {
        results[index] = result
        guard let app = apps[index] else { return }
        rows[index].show(result, of: app, isThisStrata: Self.isThisCopyOfStrata(app.url) && Updates.shared.canCheck) { [weak self] in
            // Strata's own updater takes over from here.
            self?.close(nil)
            Updates.shared.checkNow(nil)
        }
        updateSummary()
        if !results.contains(where: { $0 == nil }) {
            NSAccessibility.post(element: view, notification: .announcementRequested,
                                 userInfo: [.announcement: summary.stringValue, .priority: NSAccessibilityPriorityLevel.medium.rawValue])
        }
    }

    private func updateSummary() {
        let count = urls.count
        if results.contains(where: { $0 == nil }) {
            summary.stringValue = count == 1 ? String(localized: "Checking…", comment: "App Updates: one app is being checked")
                : String(localized: "Checking \(count) apps…", comment: "plural")
            return
        }
        let available = results.filter { if case .available = $0 { true } else { false } }.count
        let checked = results.filter { $0?.wasChecked == true }.count
        summary.isHidden = false
        if available > 0 {
            summary.stringValue = String(localized: "\(available) updates available", comment: "plural")
        } else if checked == count {
            summary.stringValue = count == 1 ? String(localized: "It’s up to date.", comment: "App Updates: the one app checked is up to date")
                : String(localized: "They’re all up to date.", comment: "App Updates: every app checked is up to date")
        } else if checked > 0 {
            summary.stringValue = String(localized: "No updates for the \(checked) apps Strata could check.", comment: "plural; App Updates: others couldn't be checked")
        } else {
            // Nothing Strata could check itself: each row says how that app is updated.
            summary.stringValue = ""
            summary.isHidden = true
        }
    }

    @objc private func close(_ sender: Any?) {
        task?.cancel()
        dismiss(nil)
    }
}

/// One app: icon, name, what the check found, and a button for what to do about it.
private final class AppUpdateRow: NSView {
    private let url: URL
    private let name: String
    private let version = NSTextField(labelWithString: "")
    private let status = NSTextField(wrappingLabelWithString: "")
    private let symbol = NSImageView()
    private let spinner = NSProgressIndicator()
    private let action = NSButton(title: "", target: nil, action: nil)
    private let notes = NSButton(title: String(localized: "What’s New", comment: "Button: read about an app's new version"), target: nil, action: nil)
    private var perform: (() -> Void)?
    private var notesPage: URL?

    init(_ url: URL) {
        self.url = url
        name = FileManager.default.displayName(atPath: url.path)
        super.init(frame: .zero)
        let icon = NSImageView(image: NSWorkspace.shared.icon(forFile: url.path))
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        let nameLabel = NSTextField(labelWithString: name)
        nameLabel.font = .systemFont(ofSize: 13, weight: .semibold)
        nameLabel.lineBreakMode = .byTruncatingTail
        nameLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        version.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        version.textColor = .tertiaryLabelColor
        version.lineBreakMode = .byTruncatingTail
        status.font = .systemFont(ofSize: 11.5)
        status.textColor = .secondaryLabelColor
        status.maximumNumberOfLines = 2
        status.lineBreakMode = .byTruncatingTail
        status.cell?.truncatesLastVisibleLine = true
        status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        symbol.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        symbol.setAccessibilityElement(false)
        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        for button in [action, notes] {
            button.bezelStyle = .push
            button.controlSize = .small
            button.isHidden = true
            button.setContentCompressionResistancePriority(.required, for: .horizontal)
            button.setContentHuggingPriority(.required, for: .horizontal)
        }
        action.target = self
        action.action = #selector(performAction)
        notes.target = self
        notes.action = #selector(openNotes)

        let nameLine = NSStackView(views: [nameLabel, version])
        nameLine.spacing = 6
        nameLine.alignment = .firstBaseline
        let statusLine = NSStackView(views: [spinner, symbol, status])
        statusLine.spacing = 4
        statusLine.alignment = .top
        let text = NSStackView(views: [nameLine, statusLine])
        text.orientation = .vertical
        text.alignment = .leading
        text.spacing = 2
        let buttons = NSStackView(views: [notes, action])
        buttons.spacing = 6
        for view in [icon, text, buttons] as [NSView] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32),
            text.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            text.centerYAnchor.constraint(equalTo: centerYAnchor),
            text.trailingAnchor.constraint(lessThanOrEqualTo: buttons.leadingAnchor, constant: -10),
            buttons.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            buttons.centerYAnchor.constraint(equalTo: centerYAnchor),
            symbol.widthAnchor.constraint(equalToConstant: 14),
        ])
        spinner.startAnimation(nil)
        symbol.isHidden = true
        status.stringValue = String(localized: "Checking…", comment: "App Updates: one app is being checked")
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        updateAccessibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func showDetails(_ app: InstalledApp) {
        version.stringValue = app.version ?? ""
        version.toolTip = app.build.map { String(localized: "Build \($0)", comment: "Tooltip: an app's build number") }
    }

    /// `updateStrata` installs a newer Strata through its own updater (when this row is the running copy).
    func show(_ result: AppUpdateResult, of app: InstalledApp, isThisStrata: Bool, updateStrata: @escaping () -> Void) {
        // A stopped spinner still takes its place in the line: it's hidden, so the symbol sits under the name.
        spinner.stopAnimation(nil)
        spinner.isHidden = true
        symbol.isHidden = false
        notes.isHidden = true
        notesPage = nil
        action.toolTip = nil
        let openApp: (String, () -> Void) = (String(localized: "Open"), { [url] in
            NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
        })
        var button: (String, () -> Void)?
        switch result {
        case .upToDate:
            set(String(localized: "Up to date", comment: "App Updates: no newer version"), "checkmark.circle.fill", .systemGreen)
        case let .available(newVersion, page):
            set(app.version.map { String(localized: "Version \(newVersion) is available (you have \($0)).", comment: "App Updates") }
                    ?? String(localized: "Version \(newVersion) is available.", comment: "App Updates"),
                "arrow.down.circle.fill", .controlAccentColor)
            if case .appStore = app.source {
                button = (String(localized: "App Store", comment: "Button: show the app in the App Store, to update it"), {
                    NSWorkspace.shared.open(page ?? URL(string: "macappstore://showUpdatesPage")!)
                })
            } else if isThisStrata {
                button = (String(localized: "Update…", comment: "Button: install Strata's update"), updateStrata)
            } else {
                // Strata doesn't install other apps' updates: the app checks its signature and installs it itself.
                button = openApp
                action.toolTip = String(localized: "Open \(name), then choose Check for Updates to install it", comment: "Tooltip; the placeholder is an app's name")
                if let page {
                    notesPage = page
                    notes.isHidden = false
                }
            }
        case let .needsNewerMacOS(newVersion, macOS):
            set(String(localized: "Version \(newVersion) needs macOS \(macOS).", comment: "App Updates: the newest version doesn't run on this Mac"), "info.circle.fill", .secondaryLabelColor)
        case .askAppStore:
            set(String(localized: "Updated through the App Store.", comment: "App Updates: an App Store app the store's lookup doesn't list"), "bag.fill", .secondaryLabelColor)
            button = (String(localized: "App Store", comment: "Button: show the app in the App Store, to update it"), {
                NSWorkspace.shared.open(URL(string: "macappstore://showUpdatesPage")!)
            })
        case .withMacOS:
            set(String(localized: "Updated with macOS.", comment: "App Updates: Apple's apps that Software Update updates"), "gearshape.fill", .secondaryLabelColor)
            button = (String(localized: "Software Update", comment: "Button: open Software Update in System Settings"), {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Software-Update-Settings.extension")!)
            })
        case .itself(let hasSparkle):
            set(hasSparkle ? String(localized: "Has its own updater: open it and choose Check for Updates.", comment: "App Updates: the app updates itself with Sparkle, set up in its code")
                    : String(localized: "Strata can’t tell how it’s updated.", comment: "App Updates: no update feed or updater Strata recognizes"),
                "arrow.triangle.2.circlepath", .secondaryLabelColor)
            button = openApp
        case .failed(let message):
            set(message, "exclamationmark.triangle.fill", .systemOrange)
            if app.source != .unreadable { button = openApp }
        }
        perform = button?.1
        action.title = button?.0 ?? ""
        action.isHidden = button == nil
        updateAccessibility()
    }

    private func set(_ text: String, _ symbolName: String, _ color: NSColor) {
        status.stringValue = text
        status.toolTip = text
        symbol.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)
        symbol.contentTintColor = color
    }

    private func updateAccessibility() {
        setAccessibilityLabel("\(name), \(status.stringValue)")
    }

    @objc private func performAction() { perform?() }

    @objc private func openNotes() {
        if let notesPage { NSWorkspace.shared.open(notesPage) }
    }
}
