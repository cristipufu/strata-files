import Foundation

/// Where Copy or Move to Other Pane sends the selection: through the server when the other pane shows a server's
/// folder, nowhere when it shows a read-only copy (an archive's, a container's) or a Trash, else through the queue.
enum OtherPaneTransfer: Equatable {
    case server
    case queue
    case refused

    static func route(into target: URL, copies: CopyProviders, servers: RemoteCopyStore) -> OtherPaneTransfer {
        if servers.contains(target) { return .server }
        guard !ReadOnlyCopies.contains(target, copies: copies), !Trash.isTrash(target) else { return .refused }
        return .queue
    }
}
