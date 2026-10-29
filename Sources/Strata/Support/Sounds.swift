import AppKit
import AudioToolbox

/// Every sound Strata plays. They stay silent until the executable turns them on, so tests, which refuse and trash
/// things all the time, play none.
package enum Sounds {
    package private(set) static var areOn = false
    private static var loaded: [String: SystemSoundID] = [:]

    package static func useApplicationSounds() {
        areOn = true
    }

    package static func beep() {
        if areOn { NSSound.beep() }
    }

    package static func movedToTrash() {
        play("move to trash")
    }

    package static func emptiedTrash() {
        play("empty trash")
    }

    /// The system's sound server plays it as a sound of the interface, so it's silent when "Play user interface sound
    /// effects" is off, as Finder's own are. A sound is loaded only once sounds are on, and loaded again next time when
    /// that failed.
    private static func play(_ name: String) {
        guard areOn else { return }
        if loaded[name] == nil { loaded[name] = finderSound(name) }
        if let sound = loaded[name] { AudioServicesPlaySystemSound(sound) }
    }

    package static func finderSound(_ name: String) -> SystemSoundID? {
        let path = "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/\(name).aif"
        var sound: SystemSoundID = 0
        return AudioServicesCreateSystemSoundID(URL(fileURLWithPath: path) as CFURL, &sound) == noErr ? sound : nil
    }
}
