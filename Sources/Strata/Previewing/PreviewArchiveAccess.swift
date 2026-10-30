import AppKit

/// Password and source ownership last only as long as this preview's archive. No credential is persisted.
@MainActor final class PreviewArchiveAccess {
    typealias Reader = @MainActor (PreviewArchiveSource, [String]?, Bool, String?) async throws -> [PreviewArchiveRecord]
    /// Its last argument says whether the copy is a preview's, taken from the cache (`PreviewArchiveLease.stream`).
    typealias Copier = @MainActor (PreviewArchiveSource, [String], URL, String?, Bool) async throws
        -> PreviewArchiveLease
    private let reader: Reader
    private let copier: Copier
    private(set) var source: PreviewArchiveSource?
    private var password: String?
    var requestPassword: ((String) async -> String?)?
    var cancelPassword: (() -> Void)?

    init(reader: @escaping Reader = {
             try await PreviewArchiveReader.read($0, member: $1, directory: $2, password: $3)
         },
         copier: @escaping Copier = {
             try await PreviewArchiveLease.stream(member: $1, in: $2, source: $0, password: $3, cached: $4)
         }) {
        self.reader = reader
        self.copier = copier
    }

    func reset(_ source: PreviewArchiveSource? = nil) {
        self.source = source
        password = nil
        cancelPassword?()
    }

    func read(member: [String]? = nil, directory: Bool = false, prompt: Bool = true) async throws -> [PreviewArchiveRecord] {
        try await withPassword(prompt: prompt) { try await self.reader($0, member, directory, $1) }
    }

    func copy(member: [String], into folder: URL, cached: Bool) async throws -> PreviewArchiveLease {
        try await withPassword(prompt: true) { try await self.copier($0, member, folder, $1, cached) }
    }

    /// Runs `read` with the password the archive takes, asking for it when the archive says so.
    private func withPassword<T>(prompt: Bool, _ read: (PreviewArchiveSource, String?) async throws -> T)
        async throws -> T {
        guard let source else { throw PreviewArchiveError.unreadable }
        var attempts = 0
        while true {
            try Task.checkCancellation()
            guard self.source === source else { throw CancellationError() }
            do {
                let result = try await read(source, password)
                try Task.checkCancellation()
                guard self.source === source else { throw CancellationError() }
                return result
            }
            catch PreviewArchiveError.password {
                try Task.checkCancellation()
                guard self.source === source else { throw CancellationError() }
                guard prompt else { throw PreviewArchiveError.password }
                password = nil
                guard attempts < 3, let requestPassword else { throw PreviewArchiveError.password }
                attempts += 1
                let answer = await requestPassword(source.chosen.url.lastPathComponent)
                try Task.checkCancellation()
                guard self.source === source, let answer else { throw CancellationError() }
                password = answer
            }
        }
    }
}

@MainActor final class PreviewPasswordPrompt {
    private var alert: NSAlert?
    private var continuation: CheckedContinuation<String?, Never>?

    static func makeAlert(_ name: String) -> NSAlert {
        let alert = NSAlert()
        alert.messageText = String(localized: "Archive Password")
        alert.informativeText = String(localized: "Enter the password for “\(name)”.")
        alert.addButton(withTitle: String(localized: "Open"))
        alert.addButton(withTitle: String(localized: "Cancel"))
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        field.setAccessibilityLabel(String(localized: "Archive Password"))
        alert.accessoryView = field
        ThemeStyle.bind(alert.window)
        return alert
    }

    func request(_ name: String, in window: NSWindow?) async -> String? {
        guard let window, window.isVisible, continuation == nil, !Task.isCancelled else { return nil }
        let alert = Self.makeAlert(name)
        guard let field = alert.accessoryView as? NSSecureTextField else { return nil }
        self.alert = alert
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                self.continuation = continuation
                alert.beginSheetModal(for: window) { [weak self, weak alert] response in
                    guard let self, self.alert === alert else { return }
                    let answer = response == .alertFirstButtonReturn ? field.stringValue : nil
                    field.stringValue = ""
                    self.finish(answer)
                }
                alert.window.makeFirstResponder(field)
            }
        } onCancel: {
            Task { @MainActor [weak self, weak alert] in
                guard let self, self.alert === alert else { return }
                cancel()
            }
        }
    }

    func cancel() {
        guard let alert else { return }
        let window = alert.window
        // Detach the continuation first: ending the sheet can synchronously call its completion.
        finish(nil)
        window.sheetParent?.endSheet(window, returnCode: .cancel)
        window.orderOut(nil)
    }

    private func finish(_ value: String?) {
        (alert?.accessoryView as? NSSecureTextField)?.stringValue = ""
        let continuation = continuation
        self.continuation = nil
        alert = nil
        continuation?.resume(returning: value)
    }
}
