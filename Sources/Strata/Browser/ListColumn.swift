import AppKit

/// How a list column shows: its title, widths and alignment.
extension ListColumn {
    var title: String {
        switch self {
        case .modified: String(localized: "Date Modified")
        case .created: String(localized: "Date Created")
        case .added: String(localized: "Date Added")
        case .size: String(localized: "Size")
        case .kind: String(localized: "Kind")
        case .tags: String(localized: "Tags")
        case .fileExtension: String(localized: "Extension", comment: "List column: the file name extension")
        case .dimensions: String(localized: "Dimensions", comment: "List column: image or movie dimensions in pixels")
        case .width: String(localized: "Width", comment: "List column: image or movie width in pixels")
        case .height: String(localized: "Height", comment: "List column: image or movie height in pixels")
        case .duration: String(localized: "Duration", comment: "List column: playing time of a movie or audio file")
        }
    }

    var preferredWidth: CGFloat {
        switch self {
        case .modified, .created, .added: 170
        case .kind, .tags: 150
        case .dimensions: 130
        default: 84
        }
    }
    var minWidth: CGFloat {
        switch self {
        case .modified, .created, .added: 110
        case .kind, .tags, .dimensions: 80
        default: 60
        }
    }
    var alignment: NSTextAlignment { [.size, .width, .height, .duration].contains(self) ? .right : .left }
}
