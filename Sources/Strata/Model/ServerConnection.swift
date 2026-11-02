import Foundation
import NetFS

/// Go ▸ Connect to Server…: mounts an SMB, AFP, NFS or WebDAV share the way Finder does. macOS asks for the name and
/// password itself (and can keep them in the Keychain); Strata never sees them unless they're typed into the address.
nonisolated package enum ServerConnection {
    package static let schemes: Set<String> = ["smb", "cifs", "afp", "nfs", "https", "http"]

    package struct Problem: Error, Equatable {
        package let message: String

        package init(message: String) {
            self.message = message
        }
    }

    /// The address as a URL to mount: "server" alone (or "server/share") means SMB, like Finder; anything but the
    /// supported kinds of server is refused.
    package static func url(from text: String) -> Result<URL, Problem> {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .failure(Problem(message: String(localized: "Type a server address, like smb://server/share."))) }
        guard !trimmed.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            return .failure(Problem(message: String(localized: "That address has characters a server address can’t.")))
        }
        let spelled = trimmed.contains("://") ? trimmed : "smb://" + trimmed
        guard let components = URLComponents(string: spelled), let scheme = components.scheme?.lowercased() else {
            return .failure(Problem(message: String(localized: "That isn’t a server address. Try smb://server/share.")))
        }
        guard schemes.contains(scheme) else {
            return .failure(Problem(message: String(localized: "Strata connects to SMB, AFP, NFS and WebDAV (https://) servers, not “\(scheme)://”.")))
        }
        guard let host = components.host, !host.isEmpty else {
            return .failure(Problem(message: String(localized: "The address needs a server name, like smb://server/share.")))
        }
        var normalized = components
        normalized.scheme = scheme
        guard let url = normalized.url else { return .failure(Problem(message: String(localized: "That isn’t a server address."))) }
        return .success(url)
    }

    /// The address as it's kept in the recent list: never with a password.
    package static func displayString(_ url: URL) -> String {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        components.password = nil
        return components.string ?? url.absoluteString
    }

    /// A mount in progress, which can be stopped. It finishes exactly once: with what NetFS reports, or (cancelled)
    /// with nil, since NetFS doesn't call back after a cancel.
    package final class Request: @unchecked Sendable {
        private let lock = NSLock()
        private var id: AsyncRequestID?
        private var cancelled = false
        private var continuation: CheckedContinuation<Result<URL, Problem>?, Never>?

        package init() {}

        package func cancel() {
            let (id, waiting) = lock.withLock { () -> (AsyncRequestID?, CheckedContinuation<Result<URL, Problem>?, Never>?) in
                cancelled = true
                defer { continuation = nil }
                return (self.id, continuation)
            }
            if let id { NetFSMountURLCancel(id) }
            waiting?.resume(returning: nil)
        }

        /// False when already cancelled (the caller finishes at once).
        fileprivate func attach(_ continuation: CheckedContinuation<Result<URL, Problem>?, Never>) -> Bool {
            lock.withLock {
                guard !cancelled else { return false }
                self.continuation = continuation
                return true
            }
        }

        fileprivate func started(_ id: AsyncRequestID?) {
            let cancelNow = lock.withLock { () -> Bool in
                self.id = id
                return cancelled
            }
            if cancelNow, let id { NetFSMountURLCancel(id) }
        }

        fileprivate func finish(_ result: Result<URL, Problem>?) {
            let waiting = lock.withLock { () -> CheckedContinuation<Result<URL, Problem>?, Never>? in
                defer { continuation = nil }
                return continuation
            }
            waiting?.resume(returning: result)
        }
    }

    /// Mounts `url` (or finds it already mounted), letting macOS ask for a name and password. Returns where it's
    /// mounted; nil when you cancelled.
    package static func mount(_ url: URL, request: Request) async -> Result<URL, Problem>? {
        await withCheckedContinuation { continuation in
            guard request.attach(continuation) else { return continuation.resume(returning: nil) }
            let open = NSMutableDictionary()
            open[kNAUIOptionKey] = kNAUIOptionAllowUI
            let mountOptions = NSMutableDictionary()
            var id: AsyncRequestID?
            let status = NetFSMountURLAsync(url as CFURL, nil, nil, nil, open, mountOptions, &id, DispatchQueue.main) { code, _, mountpoints in
                let paths = (mountpoints as? [String]) ?? []
                // Already mounted: NetFS says so (EEXIST), sometimes with where; else it's found among the mounted volumes.
                if code == 0 || code == EEXIST, let path = paths.first {
                    request.finish(.success(URL(fileURLWithPath: path, isDirectory: true)))
                } else if code == EEXIST {
                    Task {
                        let found = await mounted(url)
                        request.finish(found.map { .success(URL(fileURLWithPath: $0.path, isDirectory: true)) }
                                       ?? problem(code).map { .failure($0) })
                    }
                } else {
                    request.finish(problem(code).map { .failure($0) })
                }
            }
            if status != 0 {
                request.finish(problem(status).map { .failure($0) })
            } else {
                request.started(id)
            }
        }
    }

    /// Where `url`'s share is mounted already, by the address each mounted volume remounts from.
    /// Asked of every mounted volume (one that doesn't answer holds it up), so away from the main thread.
    @concurrent package static func mounted(_ url: URL) async -> URL? {
        func key(_ url: URL) -> String? {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false), let host = components.host?.lowercased() else { return nil }
            let scheme = components.scheme?.lowercased() == "cifs" ? "smb" : components.scheme?.lowercased() ?? ""
            let path = components.percentEncodedPath.removingPercentEncoding?.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
            return "\(scheme)://\(host)/\(path.lowercased())"
        }
        guard let wanted = key(url) else { return nil }
        let volumes = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: [.volumeURLForRemountingKey], options: []) ?? []
        return volumes.first { volume in
            (try? volume.resourceValues(forKeys: [.volumeURLForRemountingKey]))?.volumeURLForRemounting.flatMap(key) == wanted
        }
    }

    /// What a mount error means, in words; nil when you cancelled.
    package static func problem(_ code: Int32) -> Problem? {
        switch code {
        // Cancelled, in the system's login window or here.
        case ECANCELED, -128: return nil
        case EAUTH, EPERM, EACCES: return Problem(message: String(localized: "The server didn’t accept the name or password."))
        case ENOENT: return Problem(message: String(localized: "The server doesn’t have that shared folder."))
        case EHOSTDOWN, EHOSTUNREACH, ENETUNREACH, ETIMEDOUT, ECONNREFUSED:
            return Problem(message: String(localized: "The server couldn’t be reached. Check the address and your network."))
        case EEXIST: return Problem(message: String(localized: "Something else is already mounted there."))
        case -5045: return Problem(message: String(localized: "The server asks you to change your password first."))
        case -5046: return Problem(message: String(localized: "The server’s password rules don’t accept that password."))
        case -5999: return Problem(message: String(localized: "Your account on the server isn’t allowed to connect now."))
        case -5998, -6003: return Problem(message: String(localized: "The server has no shared folders you can open."))
        case -5997: return Problem(message: String(localized: "The server wants a way of signing in that macOS doesn’t offer."))
        case -5996: return Problem(message: String(localized: "The server speaks a version of the protocol macOS doesn’t."))
        case -6004: return Problem(message: String(localized: "The server doesn’t allow guests. Connect with a name and password."))
        default:
            guard code > 0 else {
                return Problem(message: String(localized: "The server couldn’t be connected to (error \(String(code))).",
                                               comment: "The number is the system’s error code"))
            }
            let reason = String(cString: strerror(code))
            return Problem(message: String(localized: "The server couldn’t be connected to (\(reason))."))
        }
    }
}
