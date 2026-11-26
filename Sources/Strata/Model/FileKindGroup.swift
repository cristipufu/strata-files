import UniformTypeIdentifiers

/// A broad kind shared by folder groupings and the disk usage map.
package nonisolated enum FileKindGroup: Int, CaseIterable, Sendable {
    case folders, images, video, audio, code, archives, documents, pdfs, apps, other

    package static func of(isFolder: Bool, type: UTType?) -> FileKindGroup {
        if isFolder { return .folders }
        guard let type else { return .other }
        if type.conforms(to: .application) || type.conforms(to: .applicationBundle) { return .apps }
        if type.conforms(to: .image) { return .images }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .audio) { return .audio }
        if type.conforms(to: .archive) || type.conforms(to: .diskImage) || type.conforms(to: .zip) { return .archives }
        if type.conforms(to: .sourceCode) || type.conforms(to: .script) || type.conforms(to: .json)
            || type.conforms(to: .xml) || type.conforms(to: .yaml) || type.conforms(to: .html)
            || type.conforms(to: .propertyList) || type.conforms(to: .unixExecutable) { return .code }
        if type.conforms(to: .pdf) { return .pdfs }
        if type.conforms(to: .text) || type.conforms(to: .presentation)
            || type.conforms(to: .spreadsheet) || type.conforms(to: .compositeContent) || type.conforms(to: .epub) {
            return .documents
        }
        if type.conforms(to: .audiovisualContent) { return .video }
        return .other
    }
}
