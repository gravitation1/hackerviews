import Foundation

public struct FilterRule: Codable, Equatable, Identifiable, Sendable {
    public enum Effect: String, Codable, CaseIterable, Sendable { case block, highlight, allow, fade }
    public enum Accent: String, Codable, CaseIterable, Sendable {
        case teal, blue, purple, pink, orange, green
        public var hex: String {
            switch self {
            case .teal: "#27a99a"
            case .blue: "#599bea"
            case .purple: "#b18be8"
            case .pink: "#e98caf"
            case .orange: "#eea06c"
            case .green: "#86b96c"
            }
        }
    }
    public var id: String = UUID().uuidString
    public var enabled = true
    public var name = ""
    public var username: String? // Legacy archive field; new filters use members.
    public var members: Set<String>?
    public var assignedUsers: Set<String> {
        get { members ?? Set(username.map { [$0] } ?? []) }
        set { members = newValue; username = nil }
    }
    public static var blockedDefault: FilterRule {
        var rule = FilterRule(); rule.id = "default-blocked"; rule.name = "Blocked"; rule.members = []
        return rule
    }
    public var conditions = AccountFilters()
    public var effect: Effect = .block
    public enum FadeLevel: Int, Codable, CaseIterable, Sendable {
        case strong = 75, medium = 50, light = 25
        public var label: String {
            switch self { case .light: "Light (25%)"; case .medium: "Medium (50%)"; case .strong: "Strong (75%)" }
        }
    }
    public var fadeLevel: FadeLevel?
    public var fade: FadeLevel { fadeLevel ?? .medium }
    public var color: Accent = .teal
    public init() {}
    public var isActive: Bool { enabled && (!assignedUsers.isEmpty || conditions.isActive) }
    public var isValid: Bool {
        !id.isEmpty && id.utf8.count <= 200 && name.utf8.count <= 1000 &&
        assignedUsers.count <= 10000 && assignedUsers.allSatisfy(RecordArchive.validUsername) && conditions.isValid
    }
    public var contributionLabel: String? {
        guard effect == .highlight || effect == .fade else { return nil }
        let label = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let username { return label.isEmpty || label == username ? nil : label }
        return label.isEmpty ? "Account conditions" : label
    }
    public func contributionLabel(for author: String) -> String? {
        let label = contributionLabel
        return assignedUsers.contains(author) && label == author ? nil : label
    }
    public var result: String {
        switch effect { case .block: "blocked"; case .highlight: "highlight:" + color.hex; case .allow: "visible"; case .fade: "fade:" + String(fade.rawValue) }
    }
    public func matches(username name: String, karma: Int?, created: Date?, now: Date) -> BranchDecision {
        guard enabled else { return .visible }
        if assignedUsers.contains(name) { return .blocked }
        return conditions.evaluate(karma: karma, created: created, now: now)
    }
}

public enum RuleEvaluation {
    /// First matching declaration wins; unknown earlier conditions cannot be skipped.
    public static func effect(for username: String, rules: [FilterRule], karma: Int?, created: Date?, now: Date = Date()) -> String {
        match(for: username, rules: rules, karma: karma, created: created, now: now).effect
    }
    public static func match(for username: String, rules: [FilterRule], karma: Int?, created: Date?, now: Date = Date()) -> AccountRuleMatch {
        for (index, rule) in rules.enumerated() where rule.isActive {
            let name = rule.name.isEmpty ? (rule.username ?? "Account conditions") : rule.name
            switch rule.matches(username: username, karma: karma, created: created, now: now) {
            case .blocked:
                let label: String
                switch rule.effect {
                case .block: label = "Blocked"
                case .highlight: label = "Highlight · " + rule.color.rawValue.capitalized
                case .allow: label = "Show normally"
                case .fade: label = "Fade · " + rule.fade.label
                }
                var matched: AccountFilters? = nil
                if !rule.assignedUsers.contains(username) {
                    var conditions = rule.conditions
                    var single = rule.conditions
                    single.createdSince = nil; single.youngerThanDays = nil
                    if single.evaluate(karma: karma, created: created, now: now) != .blocked { conditions.karmaBelow = nil }
                    single = rule.conditions; single.karmaBelow = nil; single.youngerThanDays = nil
                    if single.evaluate(karma: karma, created: created, now: now) != .blocked { conditions.createdSince = nil }
                    single = rule.conditions; single.karmaBelow = nil; single.createdSince = nil
                    if single.evaluate(karma: karma, created: created, now: now) != .blocked { conditions.youngerThanDays = nil }
                    matched = conditions
                }
                return AccountRuleMatch(effect: rule.result, label: label, ruleName: name, priority: index + 1, matchedConditions: matched)
            case .unresolved:
                return AccountRuleMatch(effect: "unresolved", label: "Couldn’t verify effect", ruleName: name, priority: index + 1)
            case .visible: continue
            }
        }
        return AccountRuleMatch(effect: "visible", label: "No matching filter", ruleName: nil, priority: nil)
    }
}
