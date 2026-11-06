import Testing
@testable import StrataIndex

struct IndexClassificationTests {
    @Test(arguments: [1, 1_000])
    func repeatedProjectMarkersKeepOnlyTheirActualOutputFoldersAsNoise(projects: Int) {
        let files = (0..<projects).map { "project-\($0).csproj" } + ["package.json"]
        let folders = ["bin", "obj", "dist", "binoculars", "objects", "source"]
        var names: [UInt8] = [], items: [ScannedItem] = []
        for (index, name) in (files + folders).enumerated() {
            let bytes = Array(name.utf8)
            items.append(ScannedItem(nameOffset: names.count, nameLength: bytes.count,
                isDirectory: index >= files.count, isPackage: false, isSymlink: false, isHidden: false,
                isMountPoint: false, size: 0, mtime: 0))
            names.append(contentsOf: bytes)
        }
        let noise = names.withUnsafeBytes { IndexStore.ownNoise(items, nameBuffer: $0) }
        #expect(Array(noise.prefix(files.count)) == Array(repeating: false, count: files.count))
        #expect(Array(noise.suffix(folders.count)) == [true, true, true, false, false, false])
    }
}
