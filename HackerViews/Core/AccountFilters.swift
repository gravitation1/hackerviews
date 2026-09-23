import Foundation

public struct AccountFilters: Codable, Equatable, Sendable {
    public enum Match: String, Codable, Sendable { case any, all }
    public var enabled = true
    public var match: Match = .any
    public var preferHigher: Bool?
    public var karmaHigher: Bool?
    public var createdEarlier: Bool?
    public var ageOlder: Bool?
    public var karmaBelow: Int?
    public var createdSince: Date?
    public var youngerThanDays: Int?
    public init() {}
    public var isActive: Bool { enabled && (karmaBelow != nil || createdSince != nil || youngerThanDays != nil) }
    public var isValid: Bool {
        (karmaBelow.map { (-1_000_000...1_000_000_000).contains($0) } ?? true) &&
        (youngerThanDays.map { (1...365_000).contains($0) } ?? true) &&
        (createdSince.map { $0.timeIntervalSince1970.isFinite } ?? true)
    }
    public func evaluate(karma: Int?, created: Date?, now: Date = Date()) -> BranchDecision {
        guard isActive else { return .visible }
        var matches: [Bool?] = []
        if let limit = karmaBelow { matches.append(karma.map { (karmaHigher ?? preferHigher) == true ? $0 >= limit : $0 < limit }) }
        if let date = createdSince { matches.append(created.map { (createdEarlier ?? preferHigher) == true ? $0 < date : $0 >= date }) }
        if let days = youngerThanDays { matches.append(created.map { (ageOlder ?? preferHigher) == true ? now.timeIntervalSince($0) >= Double(days) * 86400 : now.timeIntervalSince($0) < Double(days) * 86400 }) }
        if match == .any {
            if matches.contains(where: { $0 == true }) { return .blocked }
            return matches.contains(where: { $0 == nil }) ? .unresolved : .visible
        }
        if matches.contains(where: { $0 == false }) { return .visible }
        return matches.contains(where: { $0 == nil }) ? .unresolved : .blocked
    }
}

public struct AccountFilterRevision: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    public var modifiedAt = Date()
    public var orderedRules: [FilterRule]?
    public var membershipVersion: Int?
    public var highlights: AccountFilters?
    public var linkRewrites: [LinkRewrite]?
    public var filters: AccountFilters
    public init(filters: AccountFilters) { self.filters = filters }
}

public struct FilterPolicy: Equatable, Sendable {
    public var blocked: Set<String>
    public var accounts: AccountFilters
    public var preferred: Set<String>
    public var highlights: AccountFilters
    public var rules: [FilterRule]
    public var linkRewrites: [LinkRewrite] = []
}
