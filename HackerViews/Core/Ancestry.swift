import Foundation

public struct HNItem: Codable, Sendable {
    public let id: Int
    public let by: String?
    public let parent: Int?
    public let type: String?
    public let deleted: Bool?
    public let dead: Bool?
    public let title: String?
    public let text: String?
    public let url: String?
    public let kids: [Int]?
    public let score: Int?
    public let time: Double?
    public let descendants: Int?
    public init(id: Int, by: String?, parent: Int?, type: String? = "comment", deleted: Bool? = nil, dead: Bool? = nil, title: String? = nil, text: String? = nil, url: String? = nil, kids: [Int]? = nil, score: Int? = nil, time: Double? = nil, descendants: Int? = nil) {
        self.id = id; self.by = by; self.parent = parent; self.type = type
        self.deleted = deleted; self.dead = dead
        self.title = title; self.text = text; self.url = url
        self.kids = kids; self.score = score; self.time = time; self.descendants = descendants
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

extension HNItem {
    public static func assignmentID(_ input: String) -> Int? {
        let text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = Int(text), id > 0 { return id }
        guard let url = URLComponents(string: text),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
              url.host?.lowercased() == "news.ycombinator.com", url.path == "/item",
              let raw = url.queryItems?.first(where: { $0.name == "id" })?.value,
              let id = Int(raw), id > 0 else { return nil }
        return id
    }
}
