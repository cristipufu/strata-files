import AppKit

/// Every sound Strata plays. They stay silent until the executable turns them on, so tests, which refuse and trash
/// things all the time, play none.
package enum Sounds {
    package private(set) static var areOn = false
    private static let moveToTrash = finderSound("move to trash")
    private static let emptyTrash = finderSound("empty trash")

    package static func useApplicationSounds() {
        areOn = true
    }

    package static func beep() {
        if areOn { NSSound.beep() }
    }

    package static func movedToTrash() {
        play(moveToTrash)
    }

    package static func emptiedTrash() {
        play(emptyTrash)
    }

    /// Plays `sound` from its start, so a second Trash cut short by the first still sounds. A sound is loaded only once
    /// sounds are on.
    private static func play(_ sound: @autoclosure () -> NSSound?) {
        guard areOn, let sound = sound() else { return }
        sound.stop()
        sound.play()
    }

    private static func finderSound(_ name: String) -> NSSound? {
        NSSound(contentsOfFile: "/System/Library/Components/CoreAudio.component/Contents/SharedSupport/SystemSounds/finder/\(name).aif",
                byReference: true)
    }
}
