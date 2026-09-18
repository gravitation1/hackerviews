import Foundation

public struct HNAccount: Codable, Sendable {
    public let id: String
    public let karma: Int?
    public let created: Double?
    public init(id: String, karma: Int?, created: Double?) { self.id = id; self.karma = karma; self.created = created }
}
public struct CachedAccount: Codable, Sendable {
    public var account: HNAccount
    public var fetched: Date
    public init(account: HNAccount, fetched: Date = Date()) { self.account = account; self.fetched = fetched }
    public func fresh(at now: Date) -> Bool { (0..<900).contains(now.timeIntervalSince(fetched)) }
    public func karma(at now: Date) -> Int? { fresh(at: now) ? account.karma : nil }
    public var creationDate: Date? { account.created.flatMap { $0.isFinite && $0 >= 0 ? Date(timeIntervalSince1970: $0) : nil } }
}

public struct AccountRuleMatch: Sendable {
    public var effect: String
    public var label: String
    public var ruleName: String?
    public var priority: Int?
    public var contributionCaveat = false
    public var matchedConditions: AccountFilters? = nil
}
