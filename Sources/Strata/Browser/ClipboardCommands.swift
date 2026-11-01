import AppKit

/// A pane's Copy, Cut, Paste and Copy Path, through its window's clipboard and transfers.
final class ClipboardCommands {
    private weak var context: (any BrowserCommandContext)?

    init(context: any BrowserCommandContext) {
        self.context = context
    }

    func copy(_ urls: [URL]) {
        guard let context else { return }
        let copies = context.services.copies
        let clipboard = context.services.clipboard
        // A container's or a server's items are read first (folders with all they hold, shown in Transfers), then go on
        // the clipboard as a staged copy: pasting anywhere (Finder too) gets all of them as ordinary files, never a
        // half-read copy or a link written by another machine.
        let fromContainers = urls.filter(copies.contains)
        guard fromContainers.isEmpty else {
            return context.services.transfers.add(CopyFetchJob(fromContainers, copies: copies) { [weak context] in
                let task = Task {
                    let staged = await Task.detached(priority: .userInitiated) { copies.stageForClipboard(urls) }.value
                    if !staged.isEmpty { clipboard.write(staged, cut: false) }
                }
                context?.commandWork = task
            })
        }
        clipboard.write(urls, cut: false)
    }

    func cut(_ urls: [URL]) {
        context?.services.clipboard.write(urls, cut: true)
    }

    /// What's on the clipboard, copied into `directory`, or moved with `forceMove` or after a Cut. Onto a server it's
    /// copied there (what's on this Mac stays, even after Cut; a Cut on that server moves it there).
    func paste(into directory: URL, forceMove: Bool) {
        guard let context else { return }
        let clipboard = context.services.clipboard
        let (urls, isCut) = clipboard.read()
        guard !urls.isEmpty else { return }
        let onServer = context.services.remote.copies.contains(directory)
        context.transfer(urls, into: directory, move: forceMove || isCut)
        if isCut, !onServer { clipboard.clearCut() }
    }

    /// The paths of `urls`: in a container's files, the path in the container ("/etc/hosts"); a container itself, its
    /// name. On a server, the server's address and path ("deploy@web-1:/srv/app"). Never the path of Strata's copy,
    /// which is gone when it quits.
    func copyPaths(_ urls: [URL]) {
        guard let context else { return }
        let paths = urls.compactMap(context.services.copies.clipboardPath)
        guard !paths.isEmpty else { return Sounds.beep() }
        context.services.clipboard.pasteboard.clearContents()
        context.services.clipboard.pasteboard.setString(paths.joined(separator: "\n"), forType: .string)
    }
}
