import Foundation

public struct ContentPattern: Codable, Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable { case title, url, domain, body }
    public enum Mode: String, Codable, CaseIterable, Sendable { case contains, regex }
    public var field: Field = .body
    public var mode: Mode = .contains
    /// The first pattern. Further ones live in `alternates`; a contribution
    /// matches when any pattern does. Kept as one field so saved filters from
    /// before alternates existed still decode.
    public var pattern = ""
    public var alternates: [String] = []
    public var ignoreCase = true
    public init() {}
    private enum CodingKeys: String, CodingKey { case field, mode, pattern, alternates, ignoreCase }
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        field = try container.decodeIfPresent(Field.self, forKey: .field) ?? .body
        mode = try container.decodeIfPresent(Mode.self, forKey: .mode) ?? .contains
        pattern = try container.decodeIfPresent(String.self, forKey: .pattern) ?? ""
        alternates = try container.decodeIfPresent([String].self, forKey: .alternates) ?? []
        ignoreCase = try container.decodeIfPresent(Bool.self, forKey: .ignoreCase) ?? true
    }
    /// Every entry as edited, the first included, so a list control can bind to it.
    public var patterns: [String] {
        get { [pattern] + alternates }
        set { pattern = newValue.first ?? ""; alternates = Array(newValue.dropFirst()) }
    }
    /// The entries that take part in matching.
    public var activePatterns: [String] { patterns.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } }
    /// How the patterns read in labels and summaries.
    public var summary: String {
        let active = activePatterns
        return active.count <= 1 ? (active.first ?? "") : active.map { "“" + $0 + "”" }.joined(separator: ", ")
    }
    public var error: String? {
        let active = activePatterns
        if active.isEmpty { return patterns.count > 1 ? "Enter at least one pattern." : "Enter a pattern." }
        for (index, entry) in active.enumerated() {
            let name = active.count > 1 ? "Pattern \(index + 1)" : "The pattern"
            if entry.utf8.count > 2000 { return name + " is over 2,000 bytes." }
            if mode == .regex {
                do { _ = try NSRegularExpression(pattern: entry) }
                catch { return name + " is not a valid regular expression: \(error.localizedDescription)" }
            }
        }
        return nil
    }
    public func test(_ text: String) -> (decision: BranchDecision, range: NSRange?) {
        guard error == nil, text.utf16.count <= 200_000 else { return (.unresolved, nil) }
        let expression = activePatterns.map { mode == .contains ? NSRegularExpression.escapedPattern(for: $0) : "(?:" + $0 + ")" }.joined(separator: "|")
        guard let regex = try? NSRegularExpression(pattern: expression, options: ignoreCase ? [.caseInsensitive] : []) else { return (.unresolved, nil) }
        let deadline = Date().addingTimeInterval(0.025)
        var found: NSRange?
        var expired = false
        regex.enumerateMatches(in: text, options: [.reportProgress], range: NSRange(location: 0, length: text.utf16.count)) { match, flags, stop in
            if Date() > deadline || flags.contains(.internalError) { expired = true; stop.pointee = true }
            else if let match { found = match.range; stop.pointee = true }
        }
        return (expired ? .unresolved : (found == nil ? .visible : .blocked), found)
    }
    public func evaluate(_ item: HNItem) -> BranchDecision {
        let value: String
        switch field {
        case .title: guard item.type != "comment" else { return .visible }; value = Self.readable(item.title ?? "")
        case .url: guard item.type != "comment" else { return .visible }; value = item.url ?? ""
        case .domain: guard item.type != "comment" else { return .visible }; value = URL(string: item.url ?? "")?.host ?? ""
        case .body: value = Self.readable(item.text ?? "")
        }
        return test(value).decision
    }
    public static func readable(_ html: String) -> String {
        var text = html.replacingOccurrences(of: "(?i)<(?:p|br|/p|/div|/li)(?:\\s[^>]*)?/?>", with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: "<[^>]*>", with: "", options: .regularExpression)
        let entities = ["&nbsp;": " ", "&quot;": "\"", "&apos;": "'", "&lt;": "<", "&gt;": ">"]
        for (key, value) in entities { text = text.replacingOccurrences(of: key, with: value) }
        if let regex = try? NSRegularExpression(pattern: "&#(x[0-9a-fA-F]+|[0-9]+);") {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range(at: 1), in: text), let whole = Range(match.range, in: text) else { continue }
                let digits = String(text[range])
                let number = digits.hasPrefix("x") ? UInt32(digits.dropFirst(), radix: 16) : UInt32(digits)
                if let number, let scalar = UnicodeScalar(number) { text.replaceSubrange(whole, with: String(scalar)) }
            }
        }
        return text.replacingOccurrences(of: "&amp;", with: "&")
    }
}
