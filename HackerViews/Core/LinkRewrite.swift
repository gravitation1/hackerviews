import Foundation

/// A destination the reader opens in place of another: `x.com` as
/// `xcancel.com`, keeping the path, or any link through a wrapper such as
/// `https://archive.ph/newest/{url}`.
public struct LinkRewrite: Codable, Equatable, Sendable, Identifiable {
    public var id = UUID()
    /// The site to rewrite, as a bare host. Subdomains match too.
    public var from = ""
    /// A bare host to open instead, or a template containing `{url}` (the
    /// whole link), `{host}` or `{path}` (path and query, without the leading
    /// slash, so `https://scribe.rip/{path}` reads naturally).
    public var to = ""
    public var enabled = true
    public init() {}
    public init(from: String, to: String) { self.from = from; self.to = to }

    static func host(_ text: String) -> String {
        var host = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }
    public var isTemplate: Bool { to.contains("{") }
    public var error: String? {
        let from = Self.host(self.from), to = self.to.trimmingCharacters(in: .whitespacesAndNewlines)
        if from.isEmpty { return "Enter a site to rewrite, such as x.com." }
        if from.contains(where: { "/:? ".contains($0) }) { return "Enter just the site name, without https:// or a path." }
        if !from.contains(".") { return "Enter a full site name, such as x.com." }
        if from == "news.ycombinator.com" || from == "ycombinator.com" || from.hasSuffix(".ycombinator.com") { return "Hacker News links open in the app." }
        if to.isEmpty { return "Enter the site to open instead, such as xcancel.com, or a template with {url}." }
        if isTemplate {
            let lower = to.lowercased()
            guard lower.hasPrefix("https://") || lower.hasPrefix("http://") else { return "A template starts with https:// and contains {url}, {host} or {path}." }
            guard ["{url}", "{host}", "{path}"].contains(where: to.contains) else { return "A template contains {url}, {host} or {path}." }
            if apply(to: URL(string: "https://\(from)/example?x=1")!) == nil { return "That template doesn’t produce a valid link." }
        } else {
            let target = Self.host(to)
            if target.contains(where: { "/:? ".contains($0) }) { return "Enter a site name, or a full template starting with https://." }
            if !target.contains(".") { return "Enter a full site name, such as xcancel.com." }
            if target == from { return "That opens the same site." }
        }
        return nil
    }
    public var isValid: Bool { error == nil }
    public func matches(_ url: URL) -> Bool {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? ""), let host = url.host?.lowercased() else { return false }
        let from = Self.host(self.from)
        return !from.isEmpty && (host == from || host == "www." + from || host.hasSuffix("." + from))
    }
    public func apply(to url: URL) -> URL? {
        if isTemplate {
            var path = url.path.hasPrefix("/") ? String(url.path.dropFirst()) : url.path
            if let query = url.query { path += "?" + query }
            let text = to.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "{url}", with: url.absoluteString)
                .replacingOccurrences(of: "{host}", with: url.host ?? "")
                .replacingOccurrences(of: "{path}", with: path)
            guard let result = URL(string: text), ["http", "https"].contains(result.scheme?.lowercased() ?? ""), result.host != nil else { return nil }
            return result
        }
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        parts.host = Self.host(to)
        return parts.url
    }
}

public enum LinkRewriter {
    /// The first enabled, valid rule that matches, applied once. Nil when none does.
    public static func rewrite(_ url: URL, rules: [LinkRewrite]) -> URL? {
        for rule in rules where rule.enabled && rule.isValid && rule.matches(url) { return rule.apply(to: url) }
        return nil
    }
}
