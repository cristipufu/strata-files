import AppKit

/// A capsule after the repository's crumb in the path bar: branch symbol, branch name, ↑ahead ↓behind, and a dot when
/// the work tree has changes (or the operation in progress, like "Merging"). Click for a menu to copy the branch or
/// commit. Draws itself; sizes to its content.
package final class GitBranchPill: NSView {
    package struct Model: Equatable {
        package var branch: String
        package var isDetached = false
        package var oid: String?
        package var upstream: String?
        package var ahead = 0
        package var behind = 0
        /// Changed paths (excluding ignored), or nil while unknown.
        package var changes: Int?
        package var conflicts = 0
        package var operation: String?
        package var stashCount = 0
        package var isStale = false

        package init(branch: String, isDetached: Bool = false) {
            self.branch = branch
            self.isDetached = isDetached
        }

        package init(_ snapshot: GitStatusSnapshot) {
            branch = snapshot.branch.displayName
            isDetached = snapshot.branch.isDetached
            oid = snapshot.branch.oid
            upstream = snapshot.branch.upstream
            ahead = snapshot.branch.ahead
            behind = snapshot.branch.behind
            changes = snapshot.isComplete ? snapshot.counts.changed : nil
            conflicts = snapshot.counts.conflicted
            operation = snapshot.operation?.title
            stashCount = snapshot.stashCount
            isStale = !snapshot.isComplete
        }

        /// Before status arrives: the branch straight from HEAD, so the pill shows up with the crumbs.
        package init?(placeholderFor repository: GitRepository) {
            guard let name = repository.currentBranchName() else { return nil }
            self.init(branch: name)
        }
    }

    package var model: Model? {
        didSet {
            guard model != oldValue else { return }
            isHidden = model == nil
            updateAccessibility()
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    /// Replaces the built-in menu (copy branch / commit) when set.
    package var onClick: ((GitBranchPill) -> Void)?

    private var hovering = false
    private var tracking: NSTrackingArea?

    private static let height: CGFloat = 22
    private static let padding: CGFloat = 8
    private static let symbolSlot: CGFloat = 14
    private static let maxNameWidth: CGFloat = 180
    private static let nameFont = NSFont.systemFont(ofSize: 12, weight: .medium)
    private static let countFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium)
    private static let tagFont = NSFont.systemFont(ofSize: 10, weight: .semibold)

    package override init(frame: NSRect) {
        super.init(frame: frame)
        isHidden = true
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.defaultHigh, for: .horizontal)
    }

    @available(*, unavailable)
    package required init?(coder: NSCoder) { fatalError() }

    package override var isFlipped: Bool { true }

    // MARK: Layout

    private struct Layout {
        var symbol: NSImage?
        var name: NSAttributedString
        var nameWidth: CGFloat
        var counts: NSAttributedString?
        var tag: NSAttributedString?
        var dot: NSColor?
        var width: CGFloat
    }

    private func makeLayout() -> Layout? {
        guard let model else { return nil }
        let symbolName = model.isDetached ? "smallcircle.filled.circle" : "arrow.triangle.branch"
        let symbol = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 12, weight: .medium)
                .applying(.init(paletteColors: [.secondaryLabelColor])))
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingMiddle
        let nameFont = model.isDetached ? NSFont.monospacedSystemFont(ofSize: 11.5, weight: .medium) : Self.nameFont
        let name = NSAttributedString(string: model.branch, attributes: [
            .font: nameFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph,
        ])
        let nameWidth = min(ceil(name.size().width), Self.maxNameWidth)

        var countText: [String] = []
        if model.ahead > 0 { countText.append("↑\(model.ahead)") }
        if model.behind > 0 { countText.append("↓\(model.behind)") }
        let counts = countText.isEmpty ? nil : NSAttributedString(string: countText.joined(separator: " "), attributes: [
            .font: Self.countFont, .foregroundColor: NSColor.secondaryLabelColor,
        ])

        var tag: NSAttributedString?
        if let operation = model.operation {
            tag = NSAttributedString(string: operation.uppercased(), attributes: [
                .font: Self.tagFont, .foregroundColor: GitColors.conflicted, .kern: 0.4,
            ])
        }
        var dot: NSColor?
        if tag == nil, let changes = model.changes, changes > 0 {
            dot = model.conflicts > 0 ? GitColors.conflicted : GitColors.modified
        }

        var width = Self.padding + Self.symbolSlot + 4 + nameWidth
        if let counts { width += 6 + ceil(counts.size().width) }
        if let tag { width += 6 + ceil(tag.size().width) }
        if dot != nil { width += 6 + 6 }
        width += Self.padding
        return Layout(symbol: symbol, name: name, nameWidth: nameWidth, counts: counts, tag: tag, dot: dot, width: width)
    }

    package override var intrinsicContentSize: NSSize {
        NSSize(width: makeLayout()?.width ?? 0, height: Self.height)
    }

    // MARK: Drawing

    package override func draw(_ dirtyRect: NSRect) {
        guard let layout = makeLayout() else { return }
        let capsule = NSRect(x: 0, y: (bounds.height - Self.height) / 2, width: bounds.width, height: Self.height)
        let dark = effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        let fill = NSColor.labelColor.withAlphaComponent((dark ? 0.10 : 0.06) + (hovering ? 0.05 : 0))
        fill.setFill()
        NSBezierPath(roundedRect: capsule, xRadius: Self.height / 2, yRadius: Self.height / 2).fill()

        var x = Self.padding
        let midY = capsule.midY
        if let symbol = layout.symbol {
            let size = symbol.size
            symbol.draw(in: NSRect(x: x + (Self.symbolSlot - size.width) / 2, y: midY - size.height / 2, width: size.width, height: size.height),
                        from: .zero, operation: .sourceOver, fraction: model?.isStale == true ? 0.5 : 1,
                        respectFlipped: true, hints: nil)
        }
        x += Self.symbolSlot + 4
        let nameHeight = layout.name.size().height
        layout.name.draw(with: NSRect(x: x, y: midY - nameHeight / 2, width: layout.nameWidth, height: nameHeight),
                         options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        x += layout.nameWidth
        if let counts = layout.counts {
            x += 6
            let size = counts.size()
            counts.draw(at: NSPoint(x: x, y: midY - size.height / 2))
            x += ceil(size.width)
        }
        if let tag = layout.tag {
            x += 6
            let size = tag.size()
            tag.draw(at: NSPoint(x: x, y: midY - size.height / 2))
            x += ceil(size.width)
        }
        if let dot = layout.dot {
            x += 6
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: x, y: midY - 3, width: 6, height: 6)).fill()
        }
    }

    // MARK: Interaction

    package override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInActiveApp], owner: self)
        addTrackingArea(area)
        tracking = area
    }

    package override func mouseEntered(with event: NSEvent) { hovering = true; needsDisplay = true }
    package override func mouseExited(with event: NSEvent) { hovering = false; needsDisplay = true }

    // Handled here so a click on the pill doesn't fall through to the path bar and start editing.
    package override func mouseDown(with event: NSEvent) {
        activate()
    }

    package override func accessibilityPerformPress() -> Bool {
        activate()
        return true
    }

    private func activate() {
        if let onClick { onClick(self) } else { showMenu() }
    }

    private func showMenu() {
        guard let model else { return }
        let menu = NSMenu()
        func info(_ title: String) {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
        }
        if let upstream = model.upstream {
            var line = String(localized: "Tracking \(upstream)", comment: "Git: the branch's upstream branch")
            if model.ahead > 0 || model.behind > 0 { line += " · " + aheadBehind(model) }
            info(line)
        } else if !model.isDetached {
            info(String(localized: "No upstream branch"))
        }
        if let changes = model.changes {
            info(changes == 0 ? String(localized: "Working tree clean", comment: "Git: no uncommitted changes")
                : String(localized: "\(changes) changed files", comment: "plural"))
        }
        if model.stashCount > 0 { info(String(localized: "\(model.stashCount) stashes", comment: "plural")) }
        menu.addItem(.separator())
        let copyBranch = NSMenuItem(title: model.isDetached ? String(localized: "Copy Commit ID") : String(localized: "Copy Branch Name"),
                                    action: #selector(copyBranch), keyEquivalent: "")
        copyBranch.target = self
        menu.addItem(copyBranch)
        if !model.isDetached, model.oid != nil {
            let copyCommit = NSMenuItem(title: String(localized: "Copy Commit ID"), action: #selector(copyCommit), keyEquivalent: "")
            copyCommit.target = self
            menu.addItem(copyCommit)
        }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: bounds.height + 4), in: self)
    }

    @objc private func copyBranch() {
        guard let model else { return }
        copy(model.isDetached ? (model.oid ?? model.branch) : model.branch)
    }

    @objc private func copyCommit() {
        if let oid = model?.oid { copy(oid) }
    }

    /// "3 ahead, 2 behind": each count a whole phrase.
    private func aheadBehind(_ model: Model) -> String {
        [String(localized: "\(model.ahead) ahead", comment: "plural"), String(localized: "\(model.behind) behind", comment: "plural")]
            .joined(separator: ", ")
    }

    private func copy(_ string: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
    }

    private func updateAccessibility() {
        guard let model else {
            setAccessibilityLabel(nil)
            toolTip = nil
            return
        }
        var parts = [model.isDetached ? String(localized: "Detached at \(model.branch)", comment: "Git: HEAD is detached at this commit")
                     : String(localized: "Branch \(model.branch)", comment: "Git: the current branch")]
        if let operation = model.operation { parts.append(operation) }
        if model.ahead > 0 { parts.append(String(localized: "\(model.ahead) ahead", comment: "plural")) }
        if model.behind > 0 { parts.append(String(localized: "\(model.behind) behind", comment: "plural")) }
        if let changes = model.changes {
            parts.append(changes == 0 ? String(localized: "no changes", comment: "Git, in an accessibility label: no uncommitted changes")
                : String(localized: "\(changes) changes", comment: "plural"))
        }
        if model.isStale { parts.append(String(localized: "status timed out", comment: "Git, in an accessibility label: status didn't finish in time")) }
        setAccessibilityLabel(parts.joined(separator: ", "))
        var lines = [model.isDetached ? String(localized: "Detached HEAD at \(model.branch)") : String(localized: "On branch \(model.branch)")]
        if let upstream = model.upstream { lines.append(String(localized: "Tracking \(upstream)", comment: "Git: the branch's upstream branch")) }
        if model.ahead > 0 || model.behind > 0 { lines.append(aheadBehind(model)) }
        if let changes = model.changes {
            lines.append(changes == 0 ? String(localized: "Working tree clean", comment: "Git: no uncommitted changes")
                : String(localized: "\(changes) changed files", comment: "plural"))
        }
        if model.isStale { lines.append(String(localized: "git status timed out; showing the last known state")) }
        toolTip = lines.joined(separator: "\n")
    }
}
