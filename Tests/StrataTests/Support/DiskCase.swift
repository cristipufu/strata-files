import Darwin
import Foundation

/// Whether the disk holding `folder` tells `Foo` from `foo` (a Mac's usually doesn't).
func tellsCaseApart(_ folder: URL) -> Bool {
    pathconf(folder.path, _PC_CASE_SENSITIVE) == 1
}
