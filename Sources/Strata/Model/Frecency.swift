import Foundation

/// Remembers which folders you visit, ranked by frequency weighted toward recent visits (like `zoxide`).
final class Frecency {
    static let shared = Frecency()

    private struct Visit: Codable {
        var count: Double
        var last: Date
    }

    private let key = "frecency.v1"
    private let preferences: UserDefaults
    private let now: () -> Date
    private var visits: [String: Visit] = [:]

    init(preferences: UserDefaults = Prefs.shared.defaults, now: @escaping () -> Date = Date.init) {
        self.preferences = preferences
        self.now = now
        if let data = preferences.data(forKey: key),
           let decoded = try? JSONDecoder().decode([String: Visit].self, from: data) {
            visits = decoded
        }
    }

    func record(_ url: URL) {
        let path = url.standardizedFileURL.path
        var visit = visits[path] ?? Visit(count: 0, last: now())
        visit.count += 1
        visit.last = now()
        visits[path] = visit
        if visits.count > 600 {
            let keep = ranked().prefix(500).map(\.path)
            visits = visits.filter { keep.contains($0.key) }
        }
        if let data = try? JSONEncoder().encode(visits) { preferences.set(data, forKey: key) }
    }

    /// Visited folders, best first. Whether each is still there is `PlaceChecks`' to say: this reads no disk.
    func ranked() -> [URL] {
        let now = now()
        return visits
            .filter { !$0.key.isEmpty }
            .map { (path: $0.key, score: score($0.value, now: now)) }
            .sorted { $0.score > $1.score }
            .map { URL(fileURLWithPath: $0.path, isDirectory: true) }
    }

    private func score(_ visit: Visit, now: Date) -> Double {
        let age = now.timeIntervalSince(visit.last)
        let weight: Double = age < 3600 ? 4 : age < 86_400 ? 2 : age < 604_800 ? 0.5 : 0.25
        return visit.count * weight
    }
}
