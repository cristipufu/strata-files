import Foundation
import StrataSupport

/// The parts of Get Info that change a file: its Spotlight comment, whether it's locked, and who may read and write it.
/// Nothing here asks for more rights than you have: a change you aren't allowed to make fails with the system's reason.
nonisolated package enum FileInfoEditing {
    /// Finder's levels of access for the owner, the group or everyone.
    package enum Access: Int, CaseIterable, Sendable {
        case readWrite, readOnly, writeOnly, none

        package var title: String {
            switch self {
            case .readWrite: String(localized: "Read & Write", comment: "Get Info permission level, as in Finder")
            case .readOnly: String(localized: "Read Only", comment: "Get Info permission level, as in Finder")
            case .writeOnly: String(localized: "Write Only (Drop Box)", comment: "Get Info permission level, as in Finder")
            case .none: String(localized: "No Access", comment: "Get Info permission level, as in Finder")
            }
        }

        package init(bits: mode_t) {
            switch (bits & 4 != 0, bits & 2 != 0) {
            case (true, true): self = .readWrite
            case (true, false): self = .readOnly
            case (false, true): self = .writeOnly
            case (false, false): self = .none
            }
        }
    }

    /// Who: the owner, the group, everyone. The value is the shift of their bits in a mode.
    package enum Who: Int, CaseIterable, Sendable {
        case owner = 6, group = 3, everyone = 0
    }

    package static func access(_ mode: mode_t, for who: Who) -> Access {
        Access(bits: (mode >> mode_t(who.rawValue)) & 7)
    }

    /// `mode` with `who`'s access changed. A folder's search bit follows reading or writing it (a folder you can read
    /// but not enter is no use; a drop box needs it to put things in), like Finder; a file keeps its own execute bit,
    /// except that No Access means none at all.
    package static func mode(_ mode: mode_t, setting access: Access, for who: Who, isFolder: Bool) -> mode_t {
        let shift = mode_t(who.rawValue)
        var bits: mode_t = switch access {
        case .readWrite: 6
        case .readOnly: 4
        case .writeOnly: 2
        case .none: 0
        }
        if isFolder {
            if access != .none { bits |= 1 }
        } else if access != .none {
            bits |= (mode >> shift) & 1
        }
        return (mode & ~(7 << shift)) | (bits << shift)
    }

    // MARK: - Comments

    private static let commentAttribute = "com.apple.metadata:kMDItemFinderComment"
    /// Longer comments are cut (Finder's own limit is far below this).
    package static let commentLimit = 4000

    /// The item's Spotlight comment, read without following a link.
    package static func comment(at path: String) -> String {
        let size = getxattr(path, commentAttribute, nil, 0, 0, XATTR_NOFOLLOW)
        guard size > 0, size <= 64 * 1024 else { return "" }
        var data = Data(count: size)
        let read = data.withUnsafeMutableBytes { getxattr(path, commentAttribute, $0.baseAddress, size, 0, XATTR_NOFOLLOW) }
        guard read == size, BinaryPropertyListBudget.permitsDecoding(data) else { return "" }
        if let text = try? PropertyListSerialization.propertyList(from: data, format: nil) as? String { return text }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Sets (or, when empty, removes) the item's Spotlight comment.
    package static func setComment(_ text: String, at path: String) throws {
        try setComment(text, on: ChosenFile(URL(fileURLWithPath: path)))
    }

    /// An Inspector edit keeps the item chosen when typing began, including through a delayed save or Escape.
    package static func setComment(_ text: String, on chosen: ChosenFile) throws {
        let path = chosen.url.path
        let trimmed = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(commentLimit))
        try chosen.withDescriptor { fd, _ in
            if trimmed.isEmpty {
                if fremovexattr(fd, commentAttribute, 0) != 0, errno != ENOATTR { throw posixError(path) }
                return
            }
            let data = try PropertyListSerialization.data(fromPropertyList: trimmed, format: .binary, options: 0)
            let result = data.withUnsafeBytes { fsetxattr(fd, commentAttribute, $0.baseAddress, data.count, 0, 0) }
            if result != 0 { throw posixError(path) }
        }
    }

    // MARK: - Locked and permissions

    package static func isLocked(at path: String) -> Bool {
        var info = stat()
        return lstat(path, &info) == 0 && info.st_flags & UInt32(UF_IMMUTABLE) != 0
    }

    /// Locks or unlocks the item (not a link's target).
    package static func setLocked(_ locked: Bool, at path: String) throws {
        try ChosenFile(URL(fileURLWithPath: path)).withDescriptor { fd, info in
            let flags = locked ? info.st_flags | UInt32(UF_IMMUTABLE) : info.st_flags & ~UInt32(UF_IMMUTABLE)
            if fchflags(fd, flags) != 0 { throw posixError(path) }
        }
    }

    /// Changes access through the chosen descriptor, keeping everything else about its mode.
    package static func setAccess(_ access: Access, for who: Who, at path: String) throws {
        try setAccess(access, for: who, of: ChosenFile(URL(fileURLWithPath: path)))
    }

    /// `setAccess` for the very item chosen: one put in its place since is refused.
    package static func setAccess(_ access: Access, for who: Who, of chosen: ChosenFile) throws {
        let path = chosen.url.path
        func updated(_ info: stat) throws -> mode_t {
            guard info.st_mode & S_IFMT != S_IFLNK else { throw CocoaError(.fileWriteUnsupportedScheme) }
            return mode(info.st_mode & 0o7777, setting: access, for: who, isFolder: info.st_mode & S_IFMT == S_IFDIR)
        }
        do {
            try chosen.withDescriptor { fd, info in
                if fchmod(fd, try updated(info)) != 0 { throw posixError(path) }
            }
        } catch let error as POSIXError where error.code == .EACCES {
            try chosen.withParent { parent, name, info in
                if fchmodat(parent, name, try updated(info), AT_SYMLINK_NOFOLLOW) != 0 { throw posixError(path) }
            }
        }
    }

    /// The owner's and group's names, for the permissions list.
    package static func names(at path: String) -> (owner: String, group: String, ownedByYou: Bool)? {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        var pw = passwd()
        var pwResult: UnsafeMutablePointer<passwd>?
        var pwBuffer = [CChar](repeating: 0, count: 4096)
        let owner: String
        if getpwuid_r(info.st_uid, &pw, &pwBuffer, pwBuffer.count, &pwResult) == 0,
           let ptr = pwResult?.pointee.pw_name, let name = String(validatingCString: ptr) {
            owner = name
        } else {
            owner = "\(info.st_uid)"
        }
        var gr = group()
        var grResult: UnsafeMutablePointer<group>?
        var grBuffer = [CChar](repeating: 0, count: 4096)
        let groupName: String
        if getgrgid_r(info.st_gid, &gr, &grBuffer, grBuffer.count, &grResult) == 0,
           let ptr = grResult?.pointee.gr_name, let name = String(validatingCString: ptr) {
            groupName = name
        } else {
            groupName = "\(info.st_gid)"
        }
        return (owner, groupName, info.st_uid == getuid())
    }

    package static func mode(at path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode : nil
    }

    private static func posixError(_ path: String) -> Error {
        let code = errno
        return NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: path])
    }
}
