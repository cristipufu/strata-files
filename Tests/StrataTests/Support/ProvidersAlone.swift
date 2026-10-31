import Foundation
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

extension CopyProviders {
    /// `providers` alone: their server and container stores and clipboard staging are of their own, in a temporary
    /// folder these tests never make anything in.
    init(_ providers: [any CopyProvider]) {
        let unused = FileManager.default.temporaryDirectory
            .appending(path: "strata-no-copies-\(UUID().uuidString)", directoryHint: .isDirectory)
        self.init(providers, remoteCopies: RemoteCopyStore(root: unused.appending(path: "Servers"), server: { _ in nil }),
                  containerCopies: ContainerCopyStore(root: unused.appending(path: "Containers")),
                  clipboardRoot: unused.appending(path: "Clipboard.noindex", directoryHint: .isDirectory))
    }
}
