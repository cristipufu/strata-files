import AppKit

/// Every file operation Strata performed, newest first, each undoable on its own — even after a restart.
final class HistoryWindowController: NSWindowController {
    let history: OperationLog
    private let historyUndoManager: UndoManager?

    private let table = NSTableView()
    private let empty = NSTextField(wrappingLabelWithString: String(localized: "Moves, copies, renames and deletions show up here, so you can undo them later, even after quitting."))
    private var entries: [OperationLog.Entry] = []
    private let relative: RelativeDateTimeFormatter = {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter
    }()

    init(history: OperationLog, undoManager: UndoManager?, frameAutosaveName: String? = nil) {
        self.history = history
        historyUndoManager = undoManager
        let window = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 460),
                             styleMask: [.titled, .closable, .resizable, .utilityWindow, .fullSizeContentView],
                             backing: .buffered, defer: true)
        window.title = String(localized: "History", comment: "Window title: past file operations")
        window.titlebarAppearsTransparent = true
        window.isFloatingPanel = false
        if let frameAutosaveName { window.setFrameAutosaveName(frameAutosaveName) }
        super.init(window: window)

        let column = NSTableColumn(identifier: .init("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.style = .inset
        table.rowHeight = 46
        table.dataSource = self
        table.delegate = self
        table.selectionHighlightStyle = .none

        let scroll = NSScrollView()
        scroll.documentView = table
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false

        let clear = NSButton(title: String(localized: "Clear History"), target: self, action: #selector(confirmClearHistory))
        clear.bezelStyle = .push
        clear.controlSize = .small
        let note = NSTextField(labelWithString: String(localized: "Undo any past operation, even after quitting. Undone items go back where they were."))
        note.font = .systemFont(ofSize: 11)
        note.textColor = .secondaryLabelColor
        note.lineBreakMode = .byTruncatingTail
        let footer = NSStackView(views: [note, clear])
        footer.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 10, right: 16)

        let stack = NSStackView(views: [scroll, footer])
        stack.orientation = .vertical
        stack.spacing = 0
        window.contentView = stack
        empty.font = .systemFont(ofSize: 13)
        empty.textColor = .secondaryLabelColor
        empty.alignment = .center
        empty.translatesAutoresizingMaskIntoConstraints = false
        stack.addSubview(empty)
        NSLayoutConstraint.activate([
            empty.centerXAnchor.constraint(equalTo: scroll.centerXAnchor),
            empty.centerYAnchor.constraint(equalTo: scroll.centerYAnchor),
            empty.widthAnchor.constraint(lessThanOrEqualTo: scroll.widthAnchor, constant: -60),
        ])
        NotificationCenter.default.addObserver(self, selector: #selector(reload), name: .operationLogChanged, object: history)
        reload()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    @objc private func reload() {
        entries = history.entries.reversed()
        table.reloadData()
        empty.isHidden = !entries.isEmpty
    }

    @objc private func confirmClearHistory() {
        guard let window, !entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = String(localized: "Clear the history of file operations?")
        alert.informativeText = String(localized: "You won’t be able to undo these operations from History any more. Nothing on disk changes, and items in the Trash stay there.")
        alert.addButton(withTitle: String(localized: "Clear History"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        alert.buttons[0].hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak self] response in
            self?.clearHistory(after: response)
        }
    }

    func clearHistory(after response: NSApplication.ModalResponse) {
        guard response == .alertFirstButtonReturn else { return }
        history.clear()
    }

    /// Once requested, Undo keeps its original store and native undo manager even if this panel closes.
    @discardableResult
    func undo(_ entry: OperationLog.Entry) -> Task<Void, Never> {
        Task { [weak self, history, historyUndoManager] in
            do {
                try await history.undo(entry, undoManager: historyUndoManager)
            } catch {
                guard let window = self?.window, window.isVisible else { return }
                NSAlert(error: error).beginSheetModal(for: window, completionHandler: nil)
            }
        }
    }

    fileprivate func summary(_ entry: OperationLog.Entry) -> String {
        let items = entry.kind == .move ? entry.pairs.compactMap { $0.first } : entry.created
        let first = (items.first as NSString?)?.lastPathComponent ?? ""
        let more = max(0, items.count - 1)
        switch entry.kind {
        case .move:
            let destination = entry.pairs.first.flatMap {
                $0.count == 2 && !$0[1].isEmpty ? Format.tildePath(URL(fileURLWithPath: $0[1]).deletingLastPathComponent()) : nil
            } ?? ""
            // Renames (every item stays in its folder) show the new name, not a destination.
            let inPlace = !entry.pairs.isEmpty && entry.pairs.allSatisfy {
                $0.count == 2 && ($0[0] as NSString).deletingLastPathComponent == ($0[1] as NSString).deletingLastPathComponent
            }
            if inPlace, let to = entry.pairs.first.flatMap({ $0.count == 2 ? ($0[1] as NSString).lastPathComponent : nil }) {
                return more > 0 ? String(localized: "“\(first)” → “\(to)” and \(more) more, in \(destination)", comment: "plural")
                    : String(localized: "“\(first)” → “\(to)”", comment: "History: an item renamed from one name to another")
            }
            return more > 0 ? String(localized: "“\(first)” and \(more) more → \(destination)", comment: "plural")
                : String(localized: "“\(first)” → \(destination)", comment: "History: an item moved to a folder")
        case .create:
            let folder = entry.created.first.flatMap {
                $0.isEmpty ? nil : Format.tildePath(URL(fileURLWithPath: $0).deletingLastPathComponent())
            } ?? ""
            return more > 0 ? String(localized: "“\(first)” and \(more) more in \(folder)", comment: "plural")
                : String(localized: "“\(first)” in \(folder)", comment: "History: an item created in a folder")
        }
    }

    fileprivate func when(_ date: Date) -> String {
        relative.localizedString(for: date, relativeTo: .now)
    }
}

extension HistoryWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int { entries.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard entries.indices.contains(row) else { return nil }
        let id = NSUserInterfaceItemIdentifier("HistoryCell")
        let cell = tableView.makeView(withIdentifier: id, owner: nil) as? HistoryCell ?? {
            let cell = HistoryCell()
            cell.identifier = id
            return cell
        }()
        let entry = entries[row]
        cell.configure(entry, summary: summary(entry), when: when(entry.date), canUndo: history.canUndo(entry)) { [weak self] in
            self?.undo(entry)
        }
        return cell
    }
}

private final class HistoryCell: NSTableCellView {
    private let icon = NSImageView()
    private let title = NSTextField(labelWithString: "")
    private let detail = NSTextField(labelWithString: "")
    private let button = NSButton(title: String(localized: "Undo", comment: "Button: undo this past operation"), target: nil, action: nil)
    private var action: (() -> Void)?

    override init(frame: NSRect) {
        super.init(frame: frame)
        for view in [icon, title, detail, button] {
            view.translatesAutoresizingMaskIntoConstraints = false
            addSubview(view)
        }
        icon.symbolConfiguration = .init(pointSize: 15, weight: .regular)
        icon.contentTintColor = .secondaryLabelColor
        title.font = .systemFont(ofSize: 13, weight: .medium)
        title.lineBreakMode = .byTruncatingMiddle
        detail.font = .systemFont(ofSize: 11)
        detail.textColor = .secondaryLabelColor
        detail.lineBreakMode = .byTruncatingMiddle
        button.bezelStyle = .push
        button.controlSize = .small
        button.target = self
        button.action = #selector(clicked)
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        detail.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 22),
            title.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 10),
            title.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
            title.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -10),
            detail.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            detail.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            detail.trailingAnchor.constraint(lessThanOrEqualTo: button.leadingAnchor, constant: -10),
            button.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            button.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(_ entry: OperationLog.Entry, summary: String, when: String, canUndo: Bool, undo: @escaping () -> Void) {
        let symbol: String
        switch entry.name {
        case "Move to Trash": symbol = "trash"
        case "Rename": symbol = "pencil"
        case "Copy", "Duplicate": symbol = "plus.square.on.square"
        case "New Folder": symbol = "folder.badge.plus"
        case "New File": symbol = "doc.badge.plus"
        case "Compress": symbol = "doc.zipper"
        case "Extract": symbol = "archivebox"
        case "Put Back": symbol = "tray.and.arrow.up"
        default: symbol = entry.name.hasPrefix("Undo") ? "arrow.uturn.backward" : "arrow.right.square"
        }
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        title.stringValue = entry.undone ? String(localized: "\(entry.displayName) (undone)", comment: "History: an operation that was undone; its name")
            : entry.displayName
        title.textColor = entry.undone ? .secondaryLabelColor : .labelColor
        detail.stringValue = "\(summary) · \(when)"
        button.isHidden = entry.undone
        button.isEnabled = canUndo
        button.setAccessibilityLabel(String(localized: "Undo \(entry.displayName): \(summary)", comment: "Accessibility: undo a past operation; its name and what it did"))
        button.toolTip = canUndo ? nil : String(localized: "The items have moved or been changed since.")
        action = undo
    }

    @objc private func clicked() { action?() }
}
