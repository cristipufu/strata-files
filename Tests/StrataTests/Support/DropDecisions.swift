import AppKit
@testable import Strata
@testable import StrataFiles

extension FileDrop {
    /// What dropping `urls` on `target` does, decided the way a drop is: from what the disk says, read away from the
    /// main thread.
    static func dropped(_ urls: [URL], into target: URL, mask: NSDragOperation, option: Bool,
                        copies: CopyProviders) async -> NSDragOperation {
        await decided(urls, into: target, mask: mask, option: option, copies: copies,
                      facts: DragFacts(sequence: 0, read: DragFacts.read))
    }
}
