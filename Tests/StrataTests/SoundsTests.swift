import AudioToolbox
import Testing
@testable import Strata
@testable import StrataAI
@testable import StrataDev
@testable import StrataFiles
@testable import StrataSearch

struct SoundsTests {
    @Test func aTestProcessPlaysNoSound() {
        // Only the app's executable turns sounds on: tests refuse and trash things all the time.
        #expect(!Sounds.areOn)
    }

    @Test func theTrashSoundsFollowTheSystemsSettingForInterfaceSounds() throws {
        // Loading one plays nothing.
        for name in ["move to trash", "empty trash"] {
            let sound = try #require(Sounds.finderSound(name), "\(name)")
            defer { AudioServicesDisposeSystemSoundID(sound) }
            var id = sound, isInterfaceSound: UInt32 = 0, size = UInt32(MemoryLayout<UInt32>.size)
            let read = AudioServicesGetProperty(kAudioServicesPropertyIsUISound, UInt32(MemoryLayout<SystemSoundID>.size), &id,
                                                &size, &isInterfaceSound)
            #expect(read == noErr && isInterfaceSound == 1, "\(name)")
        }
    }
}
