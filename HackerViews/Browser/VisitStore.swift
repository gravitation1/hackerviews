import Foundation

/// What the reader last saw of a discussion: when that view was taken, how
/// many comments the discussion had then, when the reader left, and where
/// reading stopped. Everything posted after `viewedAt` is new next time.
struct Visit: Codable, Equatable {
    var id: Int
    var viewedAt: Date
    var leftAt: Date
    var descendants: Int?
    var anchor: Data?
}

/// Local-only memory of visited discussions, kept beside the records file.
@MainActor
final class VisitStore {
    static let limit = 5000
    private let file: URL
    private var visits: [Int: Visit] = [:]
    private var loaded = false

    init(directory: URL) { file = directory.appendingPathComponent("visits.json") }

    private func loadIfNeeded() {
        guard !loaded else { return }
        loaded = true
        guard let data = try? Data(contentsOf: file), let list = try? JSONDecoder().decode([Visit].self, from: data) else { return }
        visits = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { $1.leftAt > $0.leftAt ? $1 : $0 })
    }
    func visit(for id: Int) -> Visit? { loadIfNeeded(); return visits[id] }
    func visits(for ids: [Int]) -> [Int: Visit] {
        loadIfNeeded()
        return ids.reduce(into: [:]) { result, id in if let visit = visits[id] { result[id] = visit } }
    }
    func record(_ visit: Visit) {
        loadIfNeeded()
        visits[visit.id] = visit
        if visits.count > Self.limit {
            let kept = visits.values.sorted { $0.leftAt > $1.leftAt }.prefix(Self.limit)
            visits = Dictionary(uniqueKeysWithValues: kept.map { ($0.id, $0) })
        }
        let list = visits.values.sorted { $0.leftAt > $1.leftAt }
        if let data = try? JSONEncoder().encode(list) { try? data.write(to: file, options: .atomic) }
    }
}
