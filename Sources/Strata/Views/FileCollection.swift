import AppKit
import UniformTypeIdentifiers

// Shared contract for the browser's alternative presentations (icons, columns, gallery, disk usage). The browser stays the
// owner of loading, sorting, filtering, file operations and Quick Look; a view only shows what it is given and
// reports what the user asked for.

/// macOS virtual key codes shared across file views, the sidebar and shortcut recording.
enum KeyCode {
    static let returnKey: UInt16 = 36
    static let tab: UInt16 = 48
    static let space: UInt16 = 49
    static let delete: UInt16 = 51
    static let escape: UInt16 = 53
    static let numpadEnter: UInt16 = 76
    static let home: UInt16 = 115
    static let forwardDelete: UInt16 = 117
    static let end: UInt16 = 119
    static let leftArrow: UInt16 = 123
    static let rightArrow: UInt16 = 124
    static let downArrow: UInt16 = 125
    static let upArrow: UInt16 = 126
}

/// Keys every view hands back to the browser instead of handling itself, mirroring `FileOutlineView`.
enum FileViewKey: Equatable {
    /// Printable characters typed with no ⌘/⌃ (the browser turns them into the filter).
    case type(String)
    case backspace
    case escape
    case returnKey
    case space
    /// Plain Tab: switches panes in dual-pane mode; otherwise the usual move to the next control.
    case tab

    static func from(_ event: NSEvent) -> FileViewKey? {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        let plain = mods.isDisjoint(with: [.command, .control])
        switch event.keyCode {
        case KeyCode.returnKey where plain, KeyCode.numpadEnter where plain:
            return .returnKey
        case KeyCode.space where plain:
            return .space
        case KeyCode.tab where mods.isEmpty:
            return .tab
        case KeyCode.escape:
            return .escape
        case KeyCode.delete where mods.isDisjoint(with: [.command, .control, .option]):
            return .backspace
        default:
            break
        }
        if plain, event.specialKey == nil, let chars = event.characters, !chars.isEmpty,
           chars.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            return .type(chars)
        }
        return nil
    }
}

protocol FileCollectionViewDelegate: AnyObject {
    /// Double-click or ⌘↓ / Return-to-open on items (files to open, folders to navigate into).
    func fileView(_ view: NSViewController, open entries: [FileEntry])
    func fileView(_ view: NSViewController, selectionDidChange urls: [URL])
    func fileView(_ view: NSViewController, menuFor entries: [FileEntry]) -> NSMenu?
    /// `folder` is nil for a drop on the background of the browser's current folder.
    func fileView(_ view: NSViewController, drop urls: [URL], onto folder: URL?, copy: Bool) -> Bool
    /// Return true when handled; unhandled keys fall through to the view's default behaviour.
    func fileView(_ view: NSViewController, handle key: FileViewKey) -> Bool
    /// Inline rename finished with a new, non-empty name that differs from the old one.
    func fileView(_ view: NSViewController, rename entry: FileEntry, to name: String)
    /// A second, slower click on the name of the only selected item (see `ClickToRename`): rename it if it may be.
    func fileView(_ view: NSViewController, renameClicked url: URL)
    /// A drag rested on `folder` long enough to spring it open; `drag` is the drag's sequence number.
    func fileView(_ view: NSViewController, springLoad folder: URL, drag: Int)
    /// Whether `folder` may spring open (readable, no privacy prompt).
    func fileView(_ view: NSViewController, canSpringLoad folder: URL) -> Bool
}

extension FileCollectionViewDelegate {
    func fileView(_ view: NSViewController, handle key: FileViewKey) -> Bool { false }
    func fileView(_ view: NSViewController, rename entry: FileEntry, to name: String) {}
    func fileView(_ view: NSViewController, renameClicked url: URL) {}
    func fileView(_ view: NSViewController, springLoad folder: URL, drag: Int) {}
    func fileView(_ view: NSViewController, canSpringLoad folder: URL) -> Bool { false }
}

/// The browser's current folder rows, already sorted and filtered. Views preserve their own selection policy.
struct FileCollectionContent {
    let directory: URL
    let entries: [FileEntry]
    let matches: [URL: [Int]]
}

/// Lookups remain with the browser: a view requests only the metadata it needs. Retained callbacks must not keep
/// their browser alive (Columns retains the comparator for folders opened later).
struct FileCollectionMetadata {
    let ordered: @MainActor (FileEntry, FileEntry) -> Bool
    let canMeasure: @MainActor (FileEntry) -> Bool
    let size: @MainActor (FileEntry) -> Int64?
    /// The same order, for folders sorted away from the main thread as they're read; nil when it can't be.
    var sortedBy: BrowserOrdering.Snapshot?
}

/// What the browser needs from whichever presentation is active.
protocol FileCollectionController: NSViewController {
    var fileDelegate: FileCollectionViewDelegate? { get set }
    var selectedEntries: [FileEntry] { get }
    func apply(_ content: FileCollectionContent, metadata: FileCollectionMetadata, animated: Bool)
    /// Columns contain nested scroll views that need the host's safe-area inset; other views handle it themselves.
    var insetsContentToSafeArea: Bool { get }
    func select(_ urls: [URL], scroll: Bool)
    /// The view to make first responder when the browser takes focus.
    var focusView: NSView { get }
    /// Where `url` is drawn, in screen coordinates (Quick Look zooms from it). Nil when not visible.
    func screenRect(for url: URL) -> NSRect?
    /// Starts inline rename of `url`; false when the item isn't shown or the view can't rename.
    @discardableResult func beginRename(_ url: URL) -> Bool
    func cancelRename()
}

extension FileCollectionController {
    var insetsContentToSafeArea: Bool { false }
    var selectedURLs: [URL] { selectedEntries.map(\.url) }
    func cancelRename() {}
}

extension URL {
    /// Identity for lookups: folder URLs from directory listings end in "/", ones built from paths don't.
    nonisolated var fileViewKey: String {
        var path = path(percentEncoded: false)
        if path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }
}

/// The browser's presentations. Raw values are what Prefs stores (new ones go at the end); `ordered` is the toolbar and
/// ⌘1–⌘5 order, which matches Finder (⌘1 Icons, ⌘2 List, ⌘3 Columns, ⌘4 Gallery), then Disk Usage.
enum BrowserViewMode: Int, CaseIterable {
    case list, grid, columns, treemap, gallery

    static let ordered: [BrowserViewMode] = [.grid, .list, .columns, .gallery, .treemap]
    /// Index in `ordered` (toolbar segment, and ⌘ number minus one).
    var position: Int { Self.ordered.firstIndex(of: self) ?? 0 }

    var title: String {
        switch self {
        case .list: String(localized: "List", comment: "View mode: items in a list")
        case .grid: String(localized: "Icons", comment: "View mode: items as icons")
        case .columns: String(localized: "Columns", comment: "View mode: items in columns")
        case .gallery: String(localized: "Gallery", comment: "View mode: items in a gallery")
        case .treemap: String(localized: "Disk Usage", comment: "View mode: items as a map of how much space they take")
        }
    }

    /// The View menu's item: "as Icons" … "as Disk Usage".
    var menuTitle: String {
        switch self {
        case .list: String(localized: "as List", comment: "View menu command: show items in a list")
        case .grid: String(localized: "as Icons", comment: "View menu command: show items as icons")
        case .columns: String(localized: "as Columns", comment: "View menu command: show items in columns")
        case .gallery: String(localized: "as Gallery", comment: "View menu command: show items in a gallery")
        case .treemap: String(localized: "as Disk Usage", comment: "View menu command: show items as a map of how much space they take")
        }
    }

    var paletteTitle: String {
        switch self {
        case .grid: String(localized: "View as Icons")
        case .list: String(localized: "View as List")
        case .columns: String(localized: "View as Columns")
        case .gallery: String(localized: "View as Gallery")
        case .treemap: String(localized: "View as Disk Usage")
        }
    }

    var symbolName: String {
        switch self {
        case .list: "list.bullet"
        case .grid: "square.grid.2x2"
        case .columns: "rectangle.split.3x1"
        case .gallery: "squares.below.rectangle"
        case .treemap: "square.split.bottomrightquarter"
        }
    }

    var keyEquivalent: String { String(position + 1) }

    var image: NSImage {
        NSImage(systemSymbolName: symbolName, accessibilityDescription: title) ?? NSImage()
    }

    /// A Finder-style segmented toolbar item; `action` receives the group, read `selectedIndex`.
    static func makeToolbarItem(_ identifier: NSToolbarItem.Identifier, target: AnyObject, action: Selector) -> NSToolbarItemGroup {
        let modes = ordered
        let group = NSToolbarItemGroup(itemIdentifier: identifier, images: modes.map(\.image), selectionMode: .selectOne,
                                       labels: modes.map(\.title), target: target, action: action)
        group.label = String(localized: "View", comment: "Toolbar item label: the view mode control")
        group.paletteLabel = String(localized: "View Mode", comment: "Toolbar customization palette label")
        group.toolTip = String(localized: "Change how items are shown (⌘1–⌘5)")
        group.controlRepresentation = .expanded
        for (item, mode) in zip(group.subitems, modes) { item.toolTip = "\(mode.menuTitle) (⌘\(mode.keyEquivalent))" }
        group.selectedIndex = 0
        return group
    }

    /// View menu items "as Icons" … "as Disk Usage" with ⌘1–⌘5; each item's tag is the mode's raw value.
    static func menuItems(action: Selector) -> [NSMenuItem] {
        ordered.map { mode in
            let item = StrataCommand.view(mode).menuItem()
            item.action = action
            return item
        }
    }
}

// MARK: - Drag and drop rules

/// Finder drop semantics shared by every presentation: move within a volume, copy across volumes, Option forces a
/// copy; never into itself or a descendant, and moving into the folder an item already lives in is a no-op.
enum FileDrop {
    /// Out of an archive opened as a folder, things are only copied: no move, no alias to a temporary copy, and no
    /// dropping on the Dock's Trash.
    static func sourceMask(_ mask: NSDragOperation, _ session: NSDraggingSession, copies: CopyProviders = .live) -> NSDragOperation {
        sourceMask(mask, session.draggingPasteboard, copies: copies)
    }

    static func sourceMask(_ mask: NSDragOperation, _ pasteboard: NSPasteboard, copies: CopyProviders = .live) -> NSDragOperation {
        let urls = urls(pasteboard, copies: copies)
        // A server's items can also move within that server (a rename there); out of it, they're copied.
        if !urls.isEmpty, urls.allSatisfy({ copies.remoteCopies.server(containing: $0) != nil }) {
            return mask.intersection([.copy, .move])
        }
        return urls.contains(where: { ReadOnlyCopies.contains($0, copies: copies) }) ? mask.intersection(.copy) : mask
    }

    static func urls(_ info: NSDraggingInfo, copies: CopyProviders = .live) -> [URL] {
        urls(info.draggingPasteboard, copies: copies)
    }

    /// Dragged files, and items of containers' files dragged within Strata.
    static func urls(_ pasteboard: NSPasteboard, copies: CopyProviders = .live) -> [URL] {
        ((pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? [])
            + containerItems(pasteboard, copies: copies)
    }

    /// What file views accept dropped on them.
    static let types: [NSPasteboard.PasteboardType] = [.fileURL, .strataContainerItem]

    /// Whether `target` is one of `urls` or inside one of them, however either is spelled (`/tmp` is `/private/tmp`).
    static func isInside(_ urls: [URL], _ target: URL) -> Bool {
        // Resolved once per drag update; items usually share a parent, so theirs are cached too.
        let resolvedTarget = TransferJob.realPath(target.standardizedFileURL.path)
        var parents: [String: String] = [:]
        return urls.contains { url in
            let parent = url.deletingLastPathComponent().path
            let real = parents[parent] ?? TransferJob.realPath(parent)
            parents[parent] = real
            let item = (real as NSString).appendingPathComponent(url.lastPathComponent)
            return resolvedTarget == item || resolvedTarget.hasPrefix(item == "/" ? "/" : item + "/")
        }
    }

    static func operation(_ urls: [URL], into target: URL, info: NSDraggingInfo, copies: CopyProviders = .live) -> NSDragOperation {
        operation(urls, into: target, mask: info.draggingSourceOperationMask, option: NSEvent.modifierFlags.contains(.option), copies: copies)
    }

    /// What dropping `urls` on `target` does, given what the source allows and whether Option is held: a move, a copy,
    /// or nothing (into itself, back where it is, into a copy that can't change).
    static func operation(_ urls: [URL], into target: URL, mask: NSDragOperation, option: Bool, copies: CopyProviders = .live) -> NSDragOperation {
        guard let first = urls.first else { return [] }
        let targetPath = target.standardizedFileURL.path
        if isInside(urls, target) { return [] }
        let remoteCopies = copies.remoteCopies
        // Onto a server: copied there, or moved within that server.
        if remoteCopies.contains(target) {
            // Strata's Servers folder, or what a removed server left: nothing goes there.
            guard let sameServer = remoteCopies.server(containing: target)?.server.id else { return [] }
            if urls.allSatisfy({ remoteCopies.server(containing: $0)?.server.id == sameServer }) {
                // Within one server: a move there, or a copy with Option, as on this Mac.
                if option { return .copy }
                return urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == targetPath }) ? [] : .move
            }
            return mask.contains(.copy) || mask.contains(.generic) ? .copy : []
        }
        // An archive opened as a folder isn't changed; what's dragged out of one is copied.
        if ReadOnlyCopies.contains(target, copies: copies) { return [] }
        let wantsCopy = option || !sameVolume(first, target) || urls.contains(where: { ReadOnlyCopies.contains($0, copies: copies) })
        let operation: NSDragOperation
        if wantsCopy || !mask.contains(.move) {
            operation = mask.contains(.copy) || mask.contains(.generic) ? .copy : []
        } else {
            operation = .move
        }
        if operation == .move, urls.allSatisfy({ $0.deletingLastPathComponent().standardizedFileURL.path == targetPath }) {
            return []
        }
        return operation
    }

    private static var volumeCache: (a: URL, b: URL, same: Bool)?

    /// Called on every drag update, so the last answer is remembered.
    static func sameVolume(_ a: URL, _ b: URL) -> Bool {
        if let cached = volumeCache, cached.a == a, cached.b == b { return cached.same }
        let va = try? a.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let vb = try? b.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier
        let same = if let va, let vb { va.isEqual(vb) } else { false }
        volumeCache = (a, b, same)
        return same
    }
}

// MARK: - Kind groups

/// Coarse file categories for color coding (treemap tiles and legend).
enum FileKindGroup: Int, CaseIterable, Sendable {
    case folders, images, video, audio, code, archives, documents, apps, other

    nonisolated static func of(isFolder: Bool, type: UTType?) -> FileKindGroup {
        if isFolder { return .folders }
        guard let type else { return .other }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .apps }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) || type.conforms(to: .zip) { return .archives }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .yaml) || type.conforms(to: .html)
            || type.conforms(to: .propertyList) || type.conforms(to: .unixExecutable) { return .code }
        if type.conforms(to: .pdf) || type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) || type.conforms(to: .epub) {
            return .documents
        }
        if type.conforms(to: .audiovisualContent) { return .video }
        return .other
    }

    var title: String {
        switch self {
        case .folders: String(localized: "Folders", comment: "Kind of file, in the disk usage legend")
        case .images: String(localized: "Images", comment: "Kind of file, in the disk usage legend")
        case .video: String(localized: "Video", comment: "Kind of file, in the disk usage legend")
        case .audio: String(localized: "Audio", comment: "Kind of file, in the disk usage legend")
        case .code: String(localized: "Code", comment: "Kind of file, in the disk usage legend")
        case .archives: String(localized: "Archives", comment: "Kind of file, in the disk usage legend")
        case .documents: String(localized: "Documents", comment: "Kind of file, in the disk usage legend")
        case .apps: String(localized: "Apps", comment: "Kind of file, in the disk usage legend")
        case .other: String(localized: "Other", comment: "Kind of file, in the disk usage legend")
        }
    }

    /// System hues, so they track the appearance and accessibility contrast settings.
    var color: NSColor {
        switch self {
        case .folders: .systemBlue
        case .images: .systemPurple
        case .video: .systemOrange
        case .audio: .systemPink
        case .code: .systemGreen
        case .archives: .systemBrown
        case .documents: .systemTeal
        case .apps: .systemIndigo
        case .other: .systemGray
        }
    }
}

// MARK: - Shared drawing helpers

struct FileViewTypography: Equatable {
    /// A placeholder until a view gets its window's settings.
    static let standard = FileViewTypography(size: Prefs.defaultNameTextSize)

    let font: NSFont
    let bold: NSFont

    init(preferences: Prefs) {
        self.init(size: preferences.nameTextSize)
    }

    private init(size: Double) {
        (font, bold) = Self.fonts(for: size)
    }

    private static var cachedFonts: [Double: (regular: NSFont, bold: NSFont)] = [:]
    private static func fonts(for size: Double) -> (regular: NSFont, bold: NSFont) {
        if let cached = cachedFonts[size] { return cached }
        let made = (regular: NSFont.systemFont(ofSize: size), bold: NSFont.systemFont(ofSize: size, weight: .bold))
        cachedFonts[size] = made
        return made
    }
}

enum FileViewStyle {
    static let detailFont = NSFont.systemFont(ofSize: 11)

    /// List rows: compact, regular or spacious, and taller for bigger names.
    static func listHeight(for preferences: Prefs) -> CGFloat {
        [22, 26, 32][min(max(preferences.density, 0), 2)] + CGFloat(preferences.nameTextSize - 13).rounded(.up)
    }

    /// Column rows, a little tighter than the list's.
    static func columnHeight(for preferences: Prefs) -> CGFloat {
        [20, 24, 30][min(max(preferences.density, 0), 2)] + CGFloat(preferences.nameTextSize - 13).rounded(.up)
    }

    /// Light, dark, or the system's (Settings ▸ Appearance).
    static func applyTheme() {
        switch Prefs.shared.theme {
        case 1: NSApp.appearance = NSAppearance(named: .aqua)
        case 2: NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }

    /// `name` with the fuzzy-match characters at `matches` (Character offsets) bold and accent-colored, like the list.
    static func highlightedName(_ name: String, matches: [Int], font: NSFont, boldFont: NSFont,
                                color: NSColor, highlight: NSColor, paragraph: NSParagraphStyle? = nil) -> NSAttributedString {
        var attributes: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: color]
        if let paragraph { attributes[.paragraphStyle] = paragraph }
        let text = NSMutableAttributedString(string: name, attributes: attributes)
        guard !matches.isEmpty else { return text }
        var offsets: [Int] = []
        var utf16 = 0
        let characters = Array(name)
        for c in characters {
            offsets.append(utf16)
            utf16 += c.utf16.count
        }
        for i in matches where i >= 0 && i < characters.count {
            text.addAttributes([.font: boldFont, .foregroundColor: highlight],
                               range: NSRange(location: offsets[i], length: characters[i].utf16.count))
        }
        return text
    }

    /// Resolves a dynamic color for layer use in `appearance`.
    static func cgColor(_ color: NSColor, in appearance: NSAppearance) -> CGColor {
        var result = color.cgColor
        appearance.performAsCurrentDrawingAppearance { result = color.cgColor }
        return result
    }

    static func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua, .vibrantDark, .vibrantLight, .accessibilityHighContrastDarkAqua,
                                    .accessibilityHighContrastAqua]).map { $0 == .darkAqua || $0 == .vibrantDark || $0 == .accessibilityHighContrastDarkAqua } ?? false
    }
}

/// Lays out a rename field over a name, Finder-style; commits on Return or focus loss, Escape cancels.
final class InlineRenameField: NSTextField, NSTextFieldDelegate {
    var onCommit: ((String) -> Void)?
    var onEnd: (() -> Void)?
    private var cancelled = false
    private var finished = false

    init(name: String, isFolder: Bool, centered: Bool, wraps: Bool? = nil, font: NSFont) {
        let multiline = wraps ?? centered
        super.init(frame: .zero)
        stringValue = name
        self.font = font
        isBezeled = true
        bezelStyle = .squareBezel
        drawsBackground = true
        backgroundColor = .textBackgroundColor
        textColor = .textColor
        focusRingType = .exterior
        alignment = centered ? .center : .natural
        usesSingleLineMode = !multiline
        cell?.wraps = multiline
        cell?.isScrollable = !multiline
        lineBreakMode = multiline ? .byCharWrapping : .byClipping
        maximumNumberOfLines = multiline ? 0 : 1
        delegate = self
        let base = isFolder ? name as NSString : (name as NSString).deletingPathExtension as NSString
        baseLength = base.length
    }

    private var baseLength = 0

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func begin(in window: NSWindow?) {
        window?.makeFirstResponder(self)
        currentEditor()?.selectedRange = NSRange(location: 0, length: baseLength)
    }

    func cancel() {
        cancelled = true
        finish()
    }

    func controlTextDidEndEditing(_ obj: Notification) { finish() }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelled = true
            finish()
            return true
        }
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            finish()
            return true
        }
        return false
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        let name = stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let commit = onCommit
        let end = onEnd
        removeFromSuperview()
        end?()
        if !cancelled, !name.isEmpty { commit?(name) }
    }
}
