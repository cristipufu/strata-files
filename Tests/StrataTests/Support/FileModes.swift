import Foundation
@testable import Strata
@testable import StrataFiles

extension FileInfoEditing {
    /// The item's own mode (not a link's target's), for tests to compare before and after a change.
    static func mode(at path: String) -> mode_t? {
        var info = stat()
        return lstat(path, &info) == 0 ? info.st_mode : nil
    }
}
