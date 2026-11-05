import AppKit
import Combine
import SwiftUI

final class SettingsFocus: ObservableObject {
    struct Request {
        let token = UUID()
        let entry: SettingEntry
    }
    private final class Anchor { weak var view: NSView?; init(_ view: NSView) { self.view = view } }
    @Published private(set) var request: Request?
    private var anchors: [SettingID: Anchor] = [:]
    private var clearing: Task<Void, Never>?

    isolated deinit { clearing?.cancel() }

    func reveal(_ entry: SettingEntry) {
        clear()
        let request = Request(entry: entry)
        self.request = request
        revealRegisteredAnchor(for: request)
    }

    private func beginClearing(_ request: Request) {
        guard clearing == nil else { return }
        clearing = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(3)) } catch { return }
            guard let self, self.request?.token == request.token else { return }
            clear()
        }
    }

    func clear() { clearing?.cancel(); clearing = nil; request = nil }

    func register(_ view: NSView, for id: SettingID) {
        anchors[id] = Anchor(view)
        if let request, request.entry.id == id { revealRegisteredAnchor(for: request) }
    }

    func unregister(_ view: NSView, for id: SettingID) {
        if anchors[id]?.view === view { anchors[id] = nil }
    }

    func anchor(for id: SettingID) -> NSView? { anchors[id]?.view }

    private func revealRegisteredAnchor(for request: Request) {
        guard let view = anchors[request.entry.id]?.view else { return }
        DispatchQueue.main.async { [weak self, weak view] in
            guard let self, self.request?.token == request.token, let view, view.window != nil else { return }
            view.window?.contentView?.layoutSubtreeIfNeeded()
            let rect = view.bounds
            guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return }
            view.scrollToVisible(rect)
            beginClearing(request)
        }
    }
}

private struct SettingsFocusKey: EnvironmentKey {
    nonisolated static let defaultValue: SettingsFocus? = nil
}

extension EnvironmentValues {
    var settingsFocus: SettingsFocus? {
        get { self[SettingsFocusKey.self] }
        set { self[SettingsFocusKey.self] = newValue }
    }
}

extension View {
    func settingAnchor(_ id: SettingID) -> some View { modifier(SettingAnchorModifier(id: id)) }
}

struct SettingsScrollTarget<Content: View>: View {
    @ObservedObject var focus: SettingsFocus
    let page: SettingsPage
    let content: Content

    init(focus: SettingsFocus, page: SettingsPage, @ViewBuilder content: () -> Content) {
        self.focus = focus; self.page = page; self.content = content()
    }

    var body: some View {
        ScrollViewReader { proxy in
            content.task(id: focus.request?.token) {
                guard let request = focus.request, request.entry.page == page else { return }
                await Task.yield()
                guard !Task.isCancelled, focus.request?.token == request.token else { return }
                proxy.scrollTo(request.entry.id, anchor: .center)
            }
        }
        .environment(\.settingsFocus, focus)
    }
}

private struct SettingAnchorModifier: ViewModifier {
    @Environment(\.settingsFocus) private var focus
    let id: SettingID
    @ViewBuilder func body(content: Content) -> some View {
        if let focus { content.modifier(SettingHighlight(id: id, focus: focus)) }
        else { content }
    }
}

private struct SettingHighlight: ViewModifier {
    let id: SettingID
    @ObservedObject var focus: SettingsFocus
    func body(content: Content) -> some View {
        content.id(id)
            .background(SettingMarker(id: id, focus: focus))
            .overlay {
                if focus.request?.entry.id == id {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(Color(nsColor: ThemeStyle.accent), lineWidth: 2)
                        .allowsHitTesting(false)
                }
            }
    }
}

private struct SettingMarker: NSViewRepresentable {
    let id: SettingID
    let focus: SettingsFocus

    func makeNSView(context: Context) -> SettingMarkerView {
        let view = SettingMarkerView()
        view.setAccessibilityElement(false)
        view.id = id; view.focus = focus
        view.identifier = NSUserInterfaceItemIdentifier("Strata.Setting." + id.rawValue)
        focus.register(view, for: id)
        return view
    }
    func updateNSView(_ view: SettingMarkerView, context: Context) {
        if view.id != id || view.focus !== focus {
            if let old = view.id { view.focus?.unregister(view, for: old) }
            view.id = id; view.focus = focus
            view.identifier = NSUserInterfaceItemIdentifier("Strata.Setting." + id.rawValue)
        }
        focus.register(view, for: id)
    }
    static func dismantleNSView(_ view: SettingMarkerView, coordinator: ()) {
        if let id = view.id { view.focus?.unregister(view, for: id) }
    }
}

private final class SettingMarkerView: NSView {
    var id: SettingID?
    weak var focus: SettingsFocus?
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
