import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataConnections
@testable import StrataDev
@testable import StrataFiles
@testable import StrataQueue
@testable import StrataModel
@testable import StrataSearch

struct FolderTreeOrderTests {
    let testEnvironment: IndependentEnvironment

    init() throws { testEnvironment = try IndependentEnvironment() }

    @Test func trashStaysLastWhetherOrNotContainersAreAvailable() throws {
        let tree = FolderTreeController(places: testEnvironment.services.places, transfers: testEnvironment.services.transfers, preferences: testEnvironment.services.preferences, remote: testEnvironment.services.remote, copies: testEnvironment.services.copies, containerStore: testEnvironment.services.containerStore, clipboard: testEnvironment.services.clipboard, watchBudget: FolderWatchers.Budget(limit: 96))
        for containers in [false, true, false, true] {
            let roots = tree.currentRoots(hasContainers: containers)
            #expect(roots.first?.url == Places.home)
            let trash = try #require(roots.last)
            #expect(trash.kind == .trash)
            #expect(trash.url == Trash.home)
            #expect(roots.filter { $0.kind == .trash }.count == 1)
            #expect(roots.filter { $0.kind == .containers }.count == (containers ? 1 : 0))
            #expect(!roots.dropLast().contains { $0.kind == .trash })
        }
    }
}
