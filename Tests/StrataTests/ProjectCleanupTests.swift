import Foundation
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

/// Clean (the project inspector's "free up space"): only build folders the project's own tools regenerate are offered
/// for the Trash, only inside the project, never through a link, and never a folder that merely has such a name.
struct ProjectCleanupTests {
    private func artifacts(_ tree: TestTree, _ project: String = "") -> [String] {
        let folder = project.isEmpty ? tree.root : tree.url(project)
        // Both sides spelled alike ("/private/var" and "/var" are the same folder).
        let base = folder.resolvingSymlinksInPath().path + "/"
        return ProjectDetector.detectSync(folder).artifacts.flatMap(\.urls).map { url in
            let path = url.resolvingSymlinksInPath().path
            return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : "outside: " + path
        }.sorted()
    }

    @Test func onlyRegenerableFoldersAreOffered() throws {
        let tree = try TestTree("package.json", "node_modules/", "node_modules/x/", ".next/", "src/", "src/app.js", "dist2/",
                                "Cargo.toml", "target/", "pyproject.toml", "pkg/", "pkg/__pycache__/", ".venv/", ".venv/pyvenv.cfg",
                                "notes/")
        #expect(artifacts(tree) == [".next", ".venv", "node_modules", "pkg/__pycache__", "target"])
    }

    @Test func aNameAloneDoesntMakeABuildFolder() throws {
        let tree = try TestTree("target/", "bin/", "obj/", "node_modules/", ".build/", "DerivedData/", "README.md")
        #expect(artifacts(tree).isEmpty)
    }

    @Test func nothingIsOfferedThroughALink() throws {
        let tree = try TestTree("elsewhere/", "elsewhere/bin/", "elsewhere/obj/", "elsewhere/keep.txt", "shared deps/",
                                "app/", "app/package.json", "app/node_modules -> shared deps",
                                "app/App.sln", "app/Lib -> elsewhere", "app/Lib2/", "app/Lib2/Lib2.csproj", "app/Lib2/bin/")
        // The linked node_modules and the linked project folder are left alone; the real project's bin is offered.
        #expect(artifacts(tree, "app") == ["Lib2/bin"])
    }

    @Test func everythingOfferedIsInsideTheProject() throws {
        let tree = try TestTree("outside/", "outside/__pycache__/", "proj/", "proj/setup.py", "proj/a/", "proj/a/__pycache__/",
                                "proj/link -> outside")
        let offered = ProjectDetector.detectSync(tree.url("proj")).artifacts.flatMap(\.urls)
        #expect(!offered.isEmpty)
        let base = tree.url("proj").resolvingSymlinksInPath().path + "/"
        #expect(offered.allSatisfy { $0.resolvingSymlinksInPath().path.hasPrefix(base) })
    }
}
