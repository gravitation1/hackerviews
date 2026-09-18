import Foundation

public enum RuleListEdits {
    public static func updating(_ rule: FilterRule, in rules: [FilterRule]) -> [FilterRule] {
        guard rule.isValid else { return rules }
        var result = rules
        if let index = result.firstIndex(where: { $0.id == rule.id }) { result[index] = rule }
        else if rule.isActive || !rule.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { result.insert(rule, at: 0) }
        return result
    }

    public struct Removed: Sendable {
        public let index: Int
        public let rule: FilterRule
    }
    public static func removed(_ ids: Set<String>, from rules: [FilterRule]) -> [Removed] {
        rules.enumerated().compactMap { ids.contains($0.element.id) ? Removed(index: $0.offset, rule: $0.element) : nil }
    }
    public static func restoring(_ removed: [Removed], into rules: [FilterRule]) -> [FilterRule] {
        var result = rules
        for entry in removed.sorted(by: { $0.index < $1.index }) where !result.contains(where: { $0.id == entry.rule.id }) {
            result.insert(entry.rule, at: min(entry.index, result.count))
        }
        return result
    }
    public static func moving(_ ids: Set<String>, in rules: [FilterRule], toEnd: Bool) -> [FilterRule] {
        let chosen = rules.filter { ids.contains($0.id) }
        let rest = rules.filter { !ids.contains($0.id) }
        return toEnd ? rest + chosen : chosen + rest
    }
}
