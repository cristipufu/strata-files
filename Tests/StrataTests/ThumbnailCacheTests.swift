import AppKit
import Testing
@testable import Strata
@testable import StrataFiles

struct ThumbnailCacheTests {
    @Test func theDefaultCacheKeepsAtMost128MiBAndKeepsTheMostRecentImages() {
        let cache = ThumbnailCache(observesMemoryPressure: false)
        let a = NSImage(size: NSSize(width: 1, height: 1))
        let b = NSImage(size: NSSize(width: 1, height: 1))
        let c = NSImage(size: NSSize(width: 1, height: 1))
        cache.insert(a, forKey: "a", cost: 64 * 1024 * 1024)
        cache.insert(b, forKey: "b", cost: 64 * 1024 * 1024)
        #expect(cache.image(forKey: "a") === a)
        cache.insert(c, forKey: "c", cost: 64 * 1024 * 1024)
        #expect(cache.image(forKey: "b") == nil)
        #expect(cache.image(forKey: "a") === a)
        #expect(cache.image(forKey: "c") === c)
    }

    @Test func replacementsOversizedImagesAndCountLimitsKeepTheBudget() {
        let cache = ThumbnailCache(costLimit: 10, countLimit: 2, observesMemoryPressure: false)
        let image = NSImage(size: NSSize(width: 1, height: 1))
        cache.insert(image, forKey: "a", cost: 8)
        cache.insert(image, forKey: "a", cost: 2)
        cache.insert(image, forKey: "b", cost: 8)
        #expect(cache.image(forKey: "a") === image)
        #expect(cache.image(forKey: "b") === image)
        cache.insert(image, forKey: "b", cost: 11)
        #expect(cache.image(forKey: "b") == nil)
        #expect(cache.image(forKey: "a") === image)
        cache.insert(image, forKey: "c", cost: 0)
        cache.insert(image, forKey: "d", cost: 0)
        #expect(cache.image(forKey: "a") == nil)
        #expect(cache.image(forKey: "c") === image)
        #expect(cache.image(forKey: "d") === image)
    }

    @Test func pressureCleanupReleasesCachedImagesWhileVisibleImagesStayUsable() {
        let cache = ThumbnailCache(observesMemoryPressure: false)
        let visible = NSImage(size: NSSize(width: 2, height: 2))
        weak var released: NSImage?
        autoreleasepool {
            let image = NSImage(size: NSSize(width: 1, height: 1))
            released = image
            cache.insert(image, forKey: "offscreen", cost: 4)
            cache.insert(visible, forKey: "onscreen", cost: 16)
        }
        #expect(released != nil)
        cache.removeAll()
        #expect(released == nil)
        #expect(cache.image(forKey: "offscreen") == nil)
        #expect(cache.image(forKey: "onscreen") == nil)
        #expect(visible.size == NSSize(width: 2, height: 2))
    }

    @Test func zeroAndMaximumBudgetsDoNotOverflowOrLoseRecency() {
        let image = NSImage(size: NSSize(width: 1, height: 1))
        let zero = ThumbnailCache(costLimit: 0, countLimit: 1, observesMemoryPressure: false)
        zero.insert(image, forKey: "empty", cost: -1)
        zero.insert(image, forKey: "tooLarge", cost: 1)
        #expect(zero.image(forKey: "empty") === image)
        #expect(zero.image(forKey: "tooLarge") == nil)
        let large = ThumbnailCache(costLimit: Int.max, observesMemoryPressure: false)
        large.insert(image, forKey: "a", cost: Int.max - 2)
        large.insert(image, forKey: "b", cost: 2)
        #expect(large.image(forKey: "a") === image)
        large.insert(image, forKey: "c", cost: 1)
        #expect(large.image(forKey: "b") == nil)
        #expect(large.image(forKey: "a") === image)
        #expect(large.image(forKey: "c") === image)
        large.removeAll()
        large.insert(image, forKey: "full", cost: Int.max)
        #expect(large.image(forKey: "full") === image)
    }

    @Test func thePressureObserverDoesNotKeepTheCacheAlive() {
        weak var released: ThumbnailCache?
        autoreleasepool {
            let cache = ThumbnailCache()
            released = cache
            cache.insert(NSImage(size: NSSize(width: 1, height: 1)), forKey: "a", cost: 4)
        }
        #expect(released == nil)
    }
}
