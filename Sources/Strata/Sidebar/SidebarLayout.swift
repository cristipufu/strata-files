/// The order of the sidebar's sections. This Mac comes right after Favorites and Frequent, as This PC comes after
/// Quick access in File Explorer; without it, Strata's own order.
enum SidebarLayout {
    static let thisMac = "thisMac"
    private static let usual = ["favorites", "workspaces", "searches", "frequent", "insights", "locations", "servers", "tags"]

    static func sectionIDs(thisMac: Bool) -> [String] {
        guard thisMac else { return usual }
        let first = ["favorites", "frequent", Self.thisMac]
        return first + usual.filter { !first.contains($0) }
    }

    static func ordered(_ sections: [SidebarSection], thisMac: Bool) -> [SidebarSection] {
        sectionIDs(thisMac: thisMac).compactMap { id in sections.first { $0.id == id } }
    }
}
