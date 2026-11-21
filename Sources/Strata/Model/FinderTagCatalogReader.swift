import Foundation
import SQLite3
import StrataIndex
import StrataSupport

/// Best-effort, read-only discovery. Apple's private catalog is optional input, never Strata's writable store.
package nonisolated enum FinderTagCatalogReader {
    private static let maximumBytes = 1 << 20
    private static let maximumIndexedFiles = 2000

    @concurrent package static func discover() async -> [FinderTag] {
        let library = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Library")
        var tags = readPlist(library.appending(path: "SyncedPreferences/com.apple.finder.plist"))
        var names = Set(tags.map { $0.name.lowercased() })
        var databases = [library.appending(path: "SyncedPreferences/com.apple.kvs/com.apple.KeyValueService-Production.sqlite")]
        let containers = library.appending(path: "Daemon Containers")
        if let children = try? FileManager.default.contentsOfDirectory(at: containers, includingPropertiesForKeys: nil) {
            databases += children.prefix(1024).map { $0.appending(path: "Data/com.apple.kvs/com.apple.KeyValueService-Production.sqlite") }
        }
        for database in databases {
            guard !Task.isCancelled, tags.count < TagCatalog.maximumEntries else { break }
            for tag in readDatabase(database) where names.insert(tag.name.lowercased()).inserted {
                tags.append(tag)
                if tags.count == TagCatalog.maximumEntries { break }
            }
        }
        if tags.isEmpty, !Task.isCancelled {
            let files = await indexedFiles()
            tags = tagsFromFiles(files)
        }
        return tags
    }

    @MainActor private static func indexedFiles() async -> [URL] {
        let predicate = NSPredicate(format: "ANY %K LIKE %@", "kMDItemUserTags", "*")
        let found = await SpotlightSearch.run(predicate, scope: nil, limit: maximumIndexedFiles, timeout: 5)
        return found.urls
    }

    /// The file attribute preserves each tag's color; Spotlight's tag names alone don't.
    package static func tagsFromFiles(_ files: [URL]) -> [FinderTag] {
        var tags: [FinderTag] = [], seen = Set<String>()
        for file in files.prefix(maximumIndexedFiles) where file.isFileURL {
            if Task.isCancelled { break }
            for tag in TagStore.read(file.path, labels: []) where seen.insert(tag.name.lowercased()).inserted {
                tags.append(tag)
                if tags.count == TagCatalog.maximumEntries { return tags }
            }
        }
        return tags
    }

    package static func readPlist(_ url: URL) -> [FinderTag] {
        guard let (data, truncated) = try? TextFile.readPrefix(url, limit: maximumBytes), !truncated,
              let root = decode(data), let values = root["values"] as? [String: Any],
              let dictionary = values["FinderTagDict"] as? [String: Any],
              let value = dictionary["value"] as? [String: Any] else { return [] }
        return tags(in: value)
    }

    package static func readDatabase(_ url: URL) -> [FinderTag] {
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX, nil) == SQLITE_OK else {
            if let handle { sqlite3_close(handle) }
            return []
        }
        guard let handle else { return [] }
        defer { sqlite3_close(handle) }
        sqlite3_busy_timeout(handle, 100)
        sqlite3_limit(handle, SQLITE_LIMIT_LENGTH, Int32(maximumBytes))
        var remainingSteps: Int32 = 10_000
        return withUnsafeMutablePointer(to: &remainingSteps) { budget in
            sqlite3_progress_handler(handle, 1000, { context in
                guard let remaining = context?.assumingMemoryBound(to: Int32.self) else { return 1 }
                remaining.pointee -= 1
                return remaining.pointee <= 0 ? 1 : 0
            }, budget)
            defer { sqlite3_progress_handler(handle, 0, nil, nil) }
            return readTags(handle)
        }
    }

    private static func readTags(_ handle: OpaquePointer) -> [FinderTag] {
        for table in ["ZSYDMANAGEDKEYVALUE", "ZSYSDMANAGEDKEYVALUE"] {
            var statement: OpaquePointer?
            let sql = "SELECT ZPLISTDATAVALUE FROM \(table) WHERE ZKEY = 'FinderTagDict' LIMIT 1"
            guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
                if let statement { sqlite3_finalize(statement) }
                continue
            }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { continue }
            let count = Int(sqlite3_column_bytes(statement, 0))
            guard count > 0, count <= maximumBytes, let bytes = sqlite3_column_blob(statement, 0) else { continue }
            return parse(Data(bytes: bytes, count: count))
        }
        return []
    }

    package static func parse(_ data: Data) -> [FinderTag] { decode(data).map(tags) ?? [] }

    private static func decode(_ data: Data) -> [String: Any]? {
        guard data.count <= maximumBytes, BinaryPropertyListBudget.permitsDecoding(data) else { return nil }
        return (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
    }

    private static func tags(in dictionary: [String: Any]) -> [FinderTag] {
        guard let values = dictionary["FinderTags"] as? [[String: Any]] else { return [] }
        var seen = Set<String>()
        return values.prefix(TagCatalog.maximumEntries).compactMap { value in
            guard let name = value["n"] as? String, !name.isEmpty, name.count <= FinderTag.maximumNameLength,
                  TagStore.clean(name) == name, !name.contains("\0"), let color = value["l"] as? Int,
                  (0...7).contains(color), seen.insert(name.lowercased()).inserted else { return nil }
            return FinderTag(name: name, color: color)
        }
    }
}
