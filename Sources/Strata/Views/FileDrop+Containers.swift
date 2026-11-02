import AppKit

extension FileDrop {
    /// Items of containers' files dragged within Strata (see `ContainerDragItem`).
    static func containerItems(_ pasteboard: NSPasteboard, copies: CopyProviders) -> [URL] {
        (pasteboard.pasteboardItems ?? []).compactMap { $0.string(forType: .strataContainerItem) }
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }.filter { copies.contains($0) }
    }
}
