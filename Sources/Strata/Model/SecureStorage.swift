import CryptoKit
import Foundation
import Security
import Synchronization
import os

/// Strata's saved state (the file index, the content index, the operation history) reveals what is inside folders that
/// macOS guards with privacy prompts, like Documents, Desktop and Downloads. A plain copy would let anything running as
/// you read it without ever asking. So every store is encrypted (AES-GCM) with a key kept in your login keychain, which
/// only Strata can read without asking you, in a folder private to your account. Files are written to a fresh
/// temporary name (never following a planted symlink) and swapped in atomically.
nonisolated package enum SecureStorage {
    private static let log = Logger(subsystem: "dev.strata.app", category: "storage")

    private static let selected = Mutex<Context?>(nil)

    /// The executable opts into the user's stores before creating any services. Importing the module, including in
    /// optimized tests, instead gets a private temporary context. Once resolved, the process context never changes.
    package static func useApplicationStorage() {
        selected.withLock { context in
            precondition(context == nil, "Configure storage before creating app services")
            context = Context(directory: URL.applicationSupportDirectory.appending(path: "Strata", directoryHint: .isDirectory),
                              caches: URL.cachesDirectory.appending(path: "dev.strata.app", directoryHint: .isDirectory),
                              keyProvider: loadOrCreateKey)
        }
    }

    /// An immutable storage dependency. Separate contexts can coexist without changing the process defaults or
    /// each other's keys. The key provider is evaluated once, on first use, even when readers run concurrently.
    package final class Context: Sendable {
        /// The process's: the user's stores once `useApplicationStorage` chose them, else a private temporary one.
        package static var shared: Context {
            selected.withLock { context in
                if let context { return context }
                let directory = FileManager.default.temporaryDirectory
                    .appending(path: "strata-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
                let made = Context(directory: directory,
                                   caches: directory.appending(path: "Caches", directoryHint: .isDirectory),
                                   key: SymmetricKey(size: .bits256), temporary: true)
                context = made
                atexit { try? FileManager.default.removeItem(at: SecureStorage.Context.shared.directory) }
                return made
            }
        }

        package let directory: URL
        package let caches: URL
        let temporary: Bool
        private enum KeyState { case pending, resolved(SymmetricKey?) }
        private let keyState = Mutex<KeyState>(.pending)
        private let keyProvider: @Sendable () -> SymmetricKey?

        package init(directory: URL, caches: URL, keyProvider: @escaping @Sendable () -> SymmetricKey?) {
            self.directory = directory
            self.caches = caches
            self.keyProvider = keyProvider
            temporary = false
            Self.prepare(directory)
            Self.prepare(caches)
        }

        package init(directory: URL, caches: URL, key: SymmetricKey?, temporary: Bool = false) {
            self.directory = directory
            self.caches = caches
            keyProvider = { key }
            self.temporary = temporary
            Self.prepare(directory)
            Self.prepare(caches)
        }

        private static func prepare(_ directory: URL) {
            var fd = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            guard fd >= 0 else { return }
            defer { close(fd) }
            let path = ChosenFile.systemSpelling(directory.path)
            for component in path.split(separator: "/") {
                let name = String(component)
                if mkdirat(fd, name, 0o700) != 0, errno != EEXIST { return }
                let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return }
                close(fd)
                fd = child
            }
            fchmod(fd, 0o700)
        }

        fileprivate var key: SymmetricKey? {
            keyState.withLock { state in
                if case .resolved(let key) = state { return key }
                let key = keyProvider()
                state = .resolved(key)
                return key
            }
        }

        /// A file or folder inside this context. Subfolders are created owner-only.
        package func url(_ relative: String, isDirectory: Bool = false) -> URL {
            let url = directory.appending(path: relative, directoryHint: isDirectory ? .isDirectory : .notDirectory)
            let folder = isDirectory ? url : url.deletingLastPathComponent()
            if folder.standardizedFileURL != directory.standardizedFileURL { Self.prepare(folder) }
            return url
        }

        /// Makes `folder` where it's missing (0700, never through a link), as naming one with `url` does.
        package func makeFolder(_ folder: URL) {
            Self.prepare(folder)
        }

        package func write(_ data: Data, to url: URL) throws {
            let writer = try Writer(url: url, storage: self)
            data.withUnsafeBytes { writer.write($0) }
            try writer.commit()
        }

        package func read(_ url: URL) -> Data? {
            guard let reader = try? Reader(url: url, storage: self) else { return nil }
            return try? reader.readToEnd()
        }
    }

    /// Deletes a store left over from before encryption (and its stray temporary file).
    package static func removeLegacy(_ url: URL) {
        for path in [url.path, url.path + ".tmp"] where FileManager.default.fileExists(atPath: path) {
            unlink(path)
        }
    }

    // MARK: Key

    private static let service = "Strata Safe Storage"
    private static let account = "dev.strata.app"

    private static func loadOrCreateKey() -> SymmetricKey? {
        let query: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecReturnData: true, kSecMatchLimit: kSecMatchLimitOne,
        ]
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard status == errSecItemNotFound else {
            log.error("Keychain key unavailable (\(status)); saved state disabled")
            return nil
        }
        let key = SymmetricKey(size: .bits256)
        let item: [CFString: Any] = [
            kSecClass: kSecClassGenericPassword, kSecAttrService: service, kSecAttrAccount: account,
            kSecAttrLabel: service,
            kSecAttrAccessible: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
            kSecAttrSynchronizable: false,
            kSecAttrDescription: String(localized: "Encrypts Strata's search index and history",
                                        comment: "Keychain item description, shown in Keychain Access"),
            kSecValueData: key.withUnsafeBytes { Data($0) },
        ]
        let added = SecItemAdd(item as CFDictionary, nil)
        guard added == errSecSuccess else {
            log.error("Couldn't store keychain key (\(added)); saved state disabled")
            return nil
        }
        return key
    }

    // MARK: Streams

    /// Format: magic, version, a random per-write salt, then chunks of up to 1 MiB plaintext, each a length-prefixed
    /// AES-GCM box whose associated data is the salt, the store's name, the chunk's index and whether it's the last
    /// one. So chunks can't be reordered, cut off, or mixed between stores or between versions of a store.
    private static let magic: UInt32 = 0x5354_5253 // "STRS"
    private static let formatVersion: UInt32 = 2
    private static let saltSize = 16
    private static let chunkSize = 1 << 20
    private static let boxOverhead = 12 + 16

    package struct Failure: Error {
        package init() {}
    }

    /// The store's identity: its path inside `directory` ("semantic/index.sealed"), else its full path. Paths are used
    /// as given: standardizing would drop a "/private" prefix only once the file exists, so writer and reader differ.
    private static func storeName(_ url: URL, directory: URL) -> Data {
        let path = url.absoluteURL.path
        let base = directory.absoluteURL.path + "/"
        return Data((path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path).utf8)
    }

    private static func associatedData(salt: Data, name: Data, index: UInt64, final: Bool) -> Data {
        var data = salt
        withUnsafeBytes(of: UInt32(name.count).littleEndian) { data.append(contentsOf: $0) }
        data.append(name)
        withUnsafeBytes(of: index.littleEndian) { data.append(contentsOf: $0) }
        data.append(final ? 1 : 0)
        return data
    }

    /// Format 1: the chunk's index and whether it's the last one.
    private static func legacyAssociatedData(_ index: UInt64, final: Bool) -> Data {
        var data = withUnsafeBytes(of: index.littleEndian) { Data($0) }
        data.append(final ? 1 : 0)
        return data
    }

    /// Temporary files a crash left behind (`<name>.<uuid>.tmp`), once they're clearly not a save in progress.
    private static func sweepStaleTemporaries(of url: URL) {
        let folder = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + "."
        let cutoff = Date().addingTimeInterval(-600)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for name in names where name.hasPrefix(prefix) && name.hasSuffix(".tmp") {
            let path = folder.appending(path: name).path
            if let modified = try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date,
               modified < cutoff {
                unlink(path)
            }
        }
    }

    /// Streams sealed chunks to a fresh temporary file; `commit()` swaps it into place.
    package final class Writer {
        private let url: URL
        private let temporary: String
        private let key: SymmetricKey
        private var fd: Int32
        private var buffer = Data()
        private var chunkIndex: UInt64 = 0
        private var failed = false
        private let salt: Data
        private let name: Data

        package init(url: URL, storage: Context) throws {
            guard let key = storage.key else { throw Failure() }
            self.url = url
            self.key = key
            salt = Data(SymmetricKey(size: .init(bitCount: saltSize * 8)).withUnsafeBytes { Data($0) })
            name = storeName(url, directory: storage.directory)
            sweepStaleTemporaries(of: url)
            temporary = url.path + "." + UUID().uuidString + ".tmp"
            fd = open(temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            buffer.reserveCapacity(chunkSize)
            var header = Data()
            withUnsafeBytes(of: magic.littleEndian) { header.append(contentsOf: $0) }
            withUnsafeBytes(of: formatVersion.littleEndian) { header.append(contentsOf: $0) }
            header.append(salt)
            header.withUnsafeBytes { put($0) }
        }

        deinit {
            if fd >= 0 {
                close(fd)
                unlink(temporary)
            }
        }

        package func write(_ bytes: UnsafeRawBufferPointer) {
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count && !failed {
                let take = min(chunkSize - buffer.count, bytes.count - offset)
                buffer.append(base.assumingMemoryBound(to: UInt8.self) + offset, count: take)
                offset += take
                if buffer.count == chunkSize { flush(final: false) }
            }
        }

        package func commit() throws {
            flush(final: true)
            let closed = close(fd)
            fd = -1
            guard !failed, closed == 0 else {
                unlink(temporary)
                throw Failure()
            }
            // rename() replaces whatever sits at `url`, a symlink included, without following it.
            guard rename(temporary, url.path) == 0 else {
                unlink(temporary)
                throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            }
        }

        private func flush(final: Bool) {
            guard !failed else { return }
            guard let box = try? AES.GCM.seal(buffer, using: key,
                                              authenticating: associatedData(salt: salt, name: name, index: chunkIndex,
                                                                             final: final)),
                  let combined = box.combined else {
                failed = true
                return
            }
            var length = UInt32(combined.count).littleEndian
            withUnsafeBytes(of: &length) { put($0) }
            combined.withUnsafeBytes { put($0) }
            chunkIndex += 1
            buffer.removeAll(keepingCapacity: true)
        }

        private func put(_ bytes: UnsafeRawBufferPointer) {
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count && !failed {
                let written = Darwin.write(fd, base + offset, bytes.count - offset)
                if written < 0, errno == EINTR { continue }
                if written <= 0 { failed = true } else { offset += written }
            }
        }
    }

    /// Reads and authenticates a sealed file one chunk at a time.
    package final class Reader {
        private let handle: FileHandle
        private let key: SymmetricKey
        private var chunk = Data()
        private var position = 0
        private var chunkIndex: UInt64 = 0
        private var sawFinal = false
        private let salt: Data
        private let name: Data
        /// Files written by the first format (no salt or store name in the associated data) are still read, so an
        /// upgrade keeps history and the content index; they're rewritten in the current format at the next save.
        private let isLegacy: Bool
        /// Upper bound on the plaintext, for sanity-checking lengths before allocating.
        package let maximumLength: Int

        package init(url: URL, storage: Context) throws {
            guard let key = storage.key else { throw Failure() }
            let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .ENOENT) }
            var info = stat()
            guard fstat(fd, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0 else {
                close(fd)
                throw Failure()
            }
            handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            self.key = key
            maximumLength = Int(info.st_size)
            guard let header = try handle.read(upToCount: 8), header.count == 8,
                  header.withUnsafeBytes({ UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) }) == magic
            else { throw Failure() }
            let version = header.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) }
            switch version {
            case formatVersion:
                guard let salt = try handle.read(upToCount: saltSize), salt.count == saltSize else { throw Failure() }
                self.salt = salt
                isLegacy = false
            case 1:
                salt = Data()
                isLegacy = true
            default:
                throw Failure()
            }
            name = storeName(url, directory: storage.directory)
        }

        /// Fills `destination` completely, or throws.
        package func read(into destination: UnsafeMutableRawBufferPointer) throws {
            guard let destBase = destination.baseAddress else { return }
            var filled = 0
            while filled < destination.count {
                if position == chunk.count { try nextChunk() }
                let take = min(chunk.count - position, destination.count - filled)
                chunk.withUnsafeBytes { source in
                    guard let srcBase = source.baseAddress else { return }
                    _ = memcpy(destBase + filled, srcBase + position, take)
                }
                position += take
                filled += take
            }
        }

        package func readToEnd() throws -> Data {
            var data = Data()
            while true {
                if position < chunk.count {
                    data.append(chunk[position...])
                    position = chunk.count
                }
                if sawFinal { break }
                try nextChunk()
            }
            try finish()
            return data
        }

        /// Confirms everything was consumed, through the final chunk (which is empty when the data filled the last one).
        package func finish() throws {
            if position == chunk.count && !sawFinal { try nextChunk() }
            guard sawFinal, position == chunk.count, try handle.read(upToCount: 1)?.isEmpty ?? true else { throw Failure() }
        }

        private func nextChunk() throws {
            guard !sawFinal, let prefix = try handle.read(upToCount: 4), prefix.count == 4 else { throw Failure() }
            let length = Int(prefix.withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) })
            guard length >= boxOverhead, length <= chunkSize + boxOverhead,
                  let combined = try handle.read(upToCount: length), combined.count == length else { throw Failure() }
            let box = try AES.GCM.SealedBox(combined: combined)
            // The last chunk is the only one sealed as final; try that only when a full-size chunk didn't open.
            func data(final: Bool) -> Data {
                isLegacy ? legacyAssociatedData(chunkIndex, final: final)
                    : associatedData(salt: salt, name: name, index: chunkIndex, final: final)
            }
            if let plain = try? AES.GCM.open(box, using: key, authenticating: data(final: false)) {
                chunk = plain
            } else {
                chunk = try AES.GCM.open(box, using: key, authenticating: data(final: true))
                sawFinal = true
            }
            position = 0
            chunkIndex += 1
        }
    }
}
