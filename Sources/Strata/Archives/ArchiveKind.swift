import Foundation

/// The archive families Strata recognizes by name: the zip family, whose preview shows its size on disk and whose
/// `__MACOSX` folder Expand drops, and the formats `tar` reads.
nonisolated package enum ArchiveKind: Sendable {
    case zip
    case tar

    package init?(fileName: String) {
        let name = fileName.lowercased()
        let ext = (name as NSString).pathExtension
        if Self.zipExtensions.contains(ext) {
            self = .zip
        } else if Self.tarExtensions.contains(ext) || Self.compressedTarSuffixes.contains(where: name.hasSuffix) {
            self = .tar
        } else {
            return nil
        }
    }

    private static let zipExtensions: Set<String> = ["cbz", "zip", "jar", "war", "ear", "aar", "apk", "aab", "ipa", "nupkg", "vsix", "whl", "xpi"]
    private static let tarExtensions: Set<String> = ["cbr", "cb7", "cbt", "tar", "tgz", "tbz", "tbz2", "txz", "tzst", "tlz", "7z", "rar", "cpio", "xar", "iso", "cab", "onepkg"]
    private static let compressedTarSuffixes = [".tar.gz", ".tar.bz2", ".tar.xz", ".tar.zst", ".tar.lz", ".tar.lzma", ".tar.z"]
}

