import Foundation

public struct HNItem: Codable, Sendable {
    public let id: Int
    public let by: String?
    public let parent: Int?
    public let type: String?
    public let deleted: Bool?
    public let dead: Bool?
    public init(id: Int, by: String?, parent: Int?, type: String? = "comment", deleted: Bool? = nil, dead: Bool? = nil) {
        self.id = id; self.by = by; self.parent = parent; self.type = type
        self.deleted = deleted; self.dead = dead
    }
}

public enum BranchDecision: String, Sendable { case visible, blocked, unresolved }

public enum Ancestry {
    /// Walk all the way through the story, including parents outside the page.
    /// Missing/deleted author information is unresolved rather than assumed safe.
    public static func classify(id: Int, blocked: Set<String>,
                                accountFiltersActive: Bool = false,
                                evaluateAuthor: @Sendable (String) async -> BranchDecision = { _ in .visible },
                                fetch: @Sendable (Int) async throws -> HNItem?) async -> BranchDecision {
        guard !blocked.isEmpty || accountFiltersActive else { return .visible }
        var cursor: Int? = id
        var visited = Set<Int>()
        var unknownAuthor = false
        do {
            while let current = cursor {
                guard visited.count < 512, visited.insert(current).inserted,
                      let item = try await fetch(current), item.id == current else { return .unresolved }
                if let author = item.by {
                    if blocked.contains(author) { return .blocked }
                    if accountFiltersActive {
                        let result = await evaluateAuthor(author)
                        if result == .blocked { return .blocked }
                        if result == .unresolved { unknownAuthor = true }
                    }
                } else if item.type != "job" {
                    unknownAuthor = true
                }
                if item.type == "comment" && item.parent == nil { return .unresolved }
                cursor = item.parent
            }
            return unknownAuthor ? .unresolved : .visible
        } catch { return .unresolved }
    }
}
