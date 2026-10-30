import Foundation

/// Text from outside Strata, such as a name or title a file gives, made fit to show on one line. Control and
/// line-breaking characters become spaces: a NUL would cut a saved name short, and a line break would hide what follows
/// it. Format characters go, a right-to-left override among them, which would reverse what follows, and so do blank
/// fillers, which would push an extension out of view. Joiners, variation selectors and tags stay, since emoji and many
/// scripts need them.
nonisolated package enum DisplayText {
    package static func oneLine(_ text: String) -> String {
        var shown = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .lineSeparator, .paragraphSeparator: shown.append(" ")
            case .format where !kept(scalar): continue
            case .otherLetter where scalar.properties.isDefaultIgnorableCodePoint: continue
            default: shown.append(scalar)
            }
        }
        return String(shown)
    }

    /// The start of a title a file gives that a native menu or label shows quickly however long the title is: at most
    /// 1200 bytes, ending between scalars, so a run of combining marks is cut too.
    package static func label(_ text: String) -> String {
        var bytes = 0, kept = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            bytes += UTF8.width(scalar)
            guard bytes <= 1200 else { break }
            kept.append(scalar)
        }
        return String(kept)
    }

    /// The zero-width non-joiner and joiner, and the tags flag emoji spell regions with.
    private static func kept(_ scalar: Unicode.Scalar) -> Bool {
        [0x200C, 0x200D].contains(scalar.value) || (0xE0020...0xE007F).contains(scalar.value)
    }
}
