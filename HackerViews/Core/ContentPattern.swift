import Foundation

public struct ContentPattern: Codable, Equatable, Sendable {
    public enum Field: String, Codable, CaseIterable, Sendable { case title, url, domain, body }
    public enum Mode: String, Codable, CaseIterable, Sendable { case contains, regex }
    public var field: Field = .body
    public var mode: Mode = .contains
    public var pattern = ""
    public var ignoreCase = true
    public init() {}
    public var error: String? {
        if pattern.isEmpty { return "Enter a pattern." }
        if pattern.utf8.count > 2000 { return "Limit patterns to 2,000 bytes." }
        if mode == .regex {
            do { _ = try NSRegularExpression(pattern: pattern) }
            catch { return "Invalid regular expression: \(error.localizedDescription)" }
        }
        return nil
    }
    public func test(_ text: String) -> (decision: BranchDecision, range: NSRange?) {
        guard error == nil, text.utf16.count <= 200_000 else { return (.unresolved, nil) }
        let expression = mode == .contains ? NSRegularExpression.escapedPattern(for: pattern) : pattern
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
