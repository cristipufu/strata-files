import Testing
@testable import StrataSupport

struct LatestUpdateTests {
    @Test func burstsScheduleOneDeliveryAndFinishingCannotPublishStaleValues() {
        let schedule = ControlledUpdates()
        var shown: [Int] = []
        let updates = LatestUpdate<Int>(schedule: schedule.schedule) { shown.append($0) }
        for value in 0..<10_000 { updates.send(value) }
        #expect(schedule.count == 1 && shown.isEmpty)
        schedule.deliverAll()
        #expect(shown == [9999])
        for value in 10_000..<20_000 { updates.send(value) }
        #expect(schedule.count == 1)
        updates.finish()
        updates.send(20_000)
        schedule.deliverAll()
        #expect(shown == [9999, 19999])
    }

    @Test func cancellationAndOwnerReleaseDropPendingAndLaterUpdates() {
        let schedule = ControlledUpdates()
        var shown: [Int] = []
        var updates: LatestUpdate<Int>? = LatestUpdate(schedule: schedule.schedule) { shown.append($0) }
        updates?.send(1)
        updates?.cancel()
        updates?.send(2)
        schedule.deliverAll()
        #expect(shown.isEmpty)
        updates = LatestUpdate(schedule: schedule.schedule) { shown.append($0) }
        weak let owner = updates
        updates?.send(3)
        updates = nil
        #expect(owner == nil)
        schedule.deliverAll()
        #expect(shown.isEmpty)
    }

    @Test func concurrentPublishersRetainOnlyTheLatestPendingUpdate() async {
        let schedule = ControlledUpdates()
        var shown: [Int] = []
        let updates = LatestUpdate<Int>(schedule: schedule.schedule) { shown.append($0) }
        await withTaskGroup(of: Void.self) { group in
            for worker in 0..<8 {
                group.addTask { for value in 0..<1000 { updates.send(worker * 1000 + value) } }
            }
        }
        updates.send(10_000)
        #expect(schedule.count == 1)
        schedule.deliverAll()
        #expect(shown == [10_000])
    }
}
