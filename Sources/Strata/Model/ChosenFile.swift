import Foundation
import StrataSupport

/// A chosen name and its parent held open across a confirmation or metadata change. Opening each component
/// without following links prevents a replaced ancestor from redirecting the operation.
nonisolated package final class ChosenFile: Sendable {
    package let url: URL
    package let identity: FileIdentity
    private let parentPath: String
    private let parentIdentity: FileIdentity
    private let parent: Int32

    package init(_ url: URL, resolveParent: Bool = true) throws {
        self.url = url
        guard !url.lastPathComponent.isEmpty, ![".", "..", "/"].contains(url.lastPathComponent) else { throw POSIXError(.EINVAL) }
        let path = url.deletingLastPathComponent().path
        parentPath = resolveParent ? try Self.resolvedDirectory(path) : Self.systemSpelling(path)
        parent = try Self.openDirectory(parentPath)
        var info = stat()
        guard fstat(parent, &info) == 0 else { close(parent); throw POSIXError(.ESTALE) }
        parentIdentity = .from(info)
        guard fstatat(parent, url.lastPathComponent, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let code = errno
            close(parent)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
        identity = .from(info)
    }

    deinit { close(parent) }

    package static func systemSpelling(_ path: String) -> String {
        // Foundation shortens /private/var back to /var. These root-owned aliases are fixed by macOS;
        // user-controlled directory components below them are still opened with O_NOFOLLOW.
        for alias in ["/var", "/tmp", "/etc"] where path == alias || path.hasPrefix(alias + "/") {
            return "/private" + path
        }
        return path
    }

    private static func resolvedDirectory(_ path: String) throws -> String {
        guard let resolved = realpath(path, nil) else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    package static func openDirectory(_ path: String) throws -> Int32 {
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(.EIO) }
        for component in systemSpelling(path).split(separator: "/") {
            guard component != ".", component != ".." else { close(fd); throw POSIXError(.EINVAL) }
            let next = openat(fd, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(fd)
            guard next >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO) }
            fd = next
        }
        return fd
    }

    private func verifyParent() throws {
        guard (try? Self.resolvedDirectory(url.deletingLastPathComponent().path)) == parentPath,
              let current = try? Self.openDirectory(parentPath) else { throw POSIXError(.ESTALE) }
        defer { close(current) }
        var info = stat()
        guard fstat(current, &info) == 0, FileIdentity.from(info) == parentIdentity else { throw POSIXError(.ESTALE) }
    }

    /// The descriptor identifies the chosen item even if its name is replaced after opening it.
    package func withDescriptor<T>(_ body: (Int32, stat) throws -> T) throws -> T {
        try verifyParent()
        let fd = openat(parent, url.lastPathComponent, O_EVTONLY | O_NONBLOCK | O_SYMLINK | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0, FileIdentity.from(info) == identity else { throw POSIXError(.ESTALE) }
        return try body(fd, info)
    }

    /// A permissions editor must also restore access to a mode-000 item, which macOS will not open even with
    /// O_EVTONLY. Its fallback uses this checked parent and AT_SYMLINK_NOFOLLOW, never a following path call.
    package func withParent<T>(_ body: (Int32, String, stat) throws -> T) throws -> T {
        try verifyParent()
        var info = stat()
        let name = url.lastPathComponent
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity.from(info) == identity else {
            throw POSIXError(.ESTALE)
        }
        return try body(parent, name, info)
    }

    package func remove() throws {
        try verifyParent()
        try Self.remove(in: parent, name: url.lastPathComponent, identity: identity, depth: 0)
    }

    private static func remove(in parent: Int32, name: String, identity: FileIdentity, depth: Int) throws {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity.from(info) == identity else {
            throw POSIXError(.ESTALE)
        }
        let isDirectory = info.st_mode & S_IFMT == S_IFDIR
        if isDirectory {
            guard depth < 512 else { throw POSIXError(.ELOOP) }
            let fd = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            defer { close(fd) }
            guard fstat(fd, &info) == 0, FileIdentity.from(info) == identity else { throw POSIXError(.ESTALE) }
            // Finish and close the listing before changing it or opening the next directory level.
            for child in try entries(in: fd) {
                try remove(in: fd, name: child.name, identity: child.identity, depth: depth + 1)
            }
        }
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0, FileIdentity.from(info) == identity else {
            throw POSIXError(.ESTALE)
        }
        guard unlinkat(parent, name, isDirectory ? AT_REMOVEDIR : 0) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    /// Capture both names and identities, each identity as its name is read. A failed listing refuses this directory
    /// before deleting its children.
    package static func entries(in fd: Int32) throws -> [(name: String, identity: FileIdentity)] {
        var children: [(name: String, identity: FileIdentity)] = []
        try forEachName(in: fd) { child in
            var info = stat()
            guard fstatat(fd, child, &info, AT_SYMLINK_NOFOLLOW) == 0 else { throw POSIXError(.ESTALE) }
            children.append((child, .from(info)))
        }
        return children
    }

    /// The names in an open folder, read without looking at the items.
    package static func names(in fd: Int32) throws -> [String] {
        var names: [String] = []
        try forEachName(in: fd) { names.append($0) }
        return names
    }

    /// A listing that fails partway, or holds a name that isn't text, fails whole.
    private static func forEachName(in fd: Int32, _ body: (String) throws -> Void) throws {
        let copy = dup(fd)
        guard copy >= 0, let stream = fdopendir(copy) else {
            let failure = errno
            if copy >= 0 { close(copy) }
            throw POSIXError(POSIXErrorCode(rawValue: failure) ?? .EIO)
        }
        defer { closedir(stream) }
        rewinddir(stream)
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                guard errno == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                return
            }
            guard let name = DirectoryEntryName.read(entry) else { throw POSIXError(.EILSEQ) }
            if name != ".", name != ".." { try body(name) }
        }
    }
}
