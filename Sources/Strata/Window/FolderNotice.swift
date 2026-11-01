import AppKit

/// What the bar under the toolbar says over a folder, and what its button does: inside a container's, a server's or
/// an archive's copy, what it is; over a Trash, the other disks' Trashes that hold something (each disk keeps its own).
struct FolderNotice: Equatable {
    enum Action: Equatable {
        case reload
        case disconnect(RemoteServer)
        case extract(URL)
        case show(URL)
        case tryAgain
    }

    let symbol: String
    let text: String
    let button: String
    let action: Action

    /// The notice over `url` when it's in a container's, a server's or an archive's copy.
    static func over(_ url: URL, containers: ContainerCopyStore, servers: RemoteCopyStore) -> FolderNotice? {
        let reload = String(localized: "Reload", comment: "Button: read a container's folder again")
        if let engine = containers.engineFolder(url) {
            return FolderNotice(symbol: "shippingbox",
                                text: String(localized: "Containers on \(engine.name). Each opens as a read-only copy of its files.",
                                             comment: "Notice over the Containers folder; placeholder: Docker Desktop, OrbStack…"),
                                button: reload, action: .reload)
        }
        if let (source, _) = containers.copy(containing: url) {
            return FolderNotice(symbol: "shippingbox",
                                text: String(localized: "Files in “\(source.name)” on \(source.engineName): a read-only copy, read from the container as you browse.",
                                             comment: "Notice over a container's files; placeholders: the container, then its engine (Docker Desktop, OrbStack…)"),
                                button: reload, action: .reload)
        }
        if let (server, _) = servers.server(containing: url) {
            let kind = server.kind == .s3 ? String(localized: "bucket", comment: "Notice: the kind of server (an S3 bucket)") : "SFTP"
            return FolderNotice(symbol: server.kind == .s3 ? "externaldrive.connected.to.line.below" : "server.rack",
                                text: String(localized: "On “\(server.name)” (\(kind)), read from the server as you browse. Changes are made on the server.",
                                             comment: "Notice over a server's files; placeholders: the server's name, then SFTP or “bucket”"),
                                button: String(localized: "Disconnect", comment: "Button: end the connection to the server"),
                                action: .disconnect(server))
        }
        if let (archive, _) = ArchiveCache.archive(containing: url) {
            return FolderNotice(symbol: "archivebox",
                                text: String(localized: "Inside “\(archive.lastPathComponent)”, a read-only copy. Copy things out to keep them."),
                                button: String(localized: "Extract All"), action: .extract(archive))
        }
        return nil
    }

    /// Over the Trash `shown`: the disks among `trashes` whose own Trash holds something, the first a click away.
    static func otherTrashes(_ trashes: [Trash.Contents], besides shown: URL) -> FolderNotice? {
        let others = trashes.filter { $0.count > 0 && $0.folder.lexicallyStandardized != shown.lexicallyStandardized }
        guard let first = others.first else { return nil }
        let text: String
        if others.count == 1 {
            text = String(localized: "“\(first.disk)” has \(first.count) more items in its own Trash.", comment: "plural")
        } else {
            let disks = ListFormatter.localizedString(byJoining: others.map {
                String(localized: "“\($0.disk)” (\($0.count.formatted()))", comment: "A disk and how many items its Trash holds")
            })
            text = String(localized: "Other disks have items in their own Trash: \(disks).", comment: "A list of disks with their item counts")
        }
        return FolderNotice(symbol: "externaldrive", text: text,
                            button: String(localized: "Show “\(first.disk)”", comment: "Button: show that disk's Trash"),
                            action: .show(first.folder))
    }

    /// A container's folder couldn't be read, for `message`.
    static func problem(_ message: String) -> FolderNotice {
        FolderNotice(symbol: "exclamationmark.triangle", text: message,
                     button: String(localized: "Try Again", comment: "Button: read a container's folder again"), action: .tryAgain)
    }
}
