import Foundation

public struct Citation: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var url: String
    public var author: String
    public var excerpt: String
    public var context: String
    public var annotation: String = ""
    public var savedIntentionally: Bool?
    public var capturedAt: Date = Date()

    public init(url: String, author: String, excerpt: String, context: String) {
        self.url = url; self.author = author; self.excerpt = excerpt; self.context = context
    }
}

/// An immutable revision. Concurrent edits remain available in history, even
/// when a deterministic newer revision becomes the current record.
public struct PersonRevision: Codable, Identifiable, Equatable, Sendable {
    public var id: UUID = UUID()
    public var username: String
    public var isPreferred: Bool?
    public var isBlocked: Bool
    public var note: String
    public var citations: [Citation]
    public var createdAt: Date
    public var modifiedAt: Date = Date()
    public var device: String
    public var parentIDs: [UUID]

    public init(username: String, isBlocked: Bool, note: String, citations: [Citation],
                createdAt: Date = Date(), device: String = "", parentIDs: [UUID] = []) {
        self.username = username; self.isBlocked = isBlocked; self.note = note
        self.citations = citations; self.createdAt = createdAt
        self.device = device; self.parentIDs = parentIDs
    }
}

public struct RecordArchive: Codable, Sendable {
    public var formatVersion: Int = 1
    public var revisions: [PersonRevision] = []
    public var filterRevisions: [AccountFilterRevision]?
    public var accountFilters: AccountFilters {
        filterRevisions?.max {
            $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt < $1.modifiedAt
        }?.filters ?? AccountFilters()
    }
    public var highlightFilters: AccountFilters {
        filterRevisions?.max {
            $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt < $1.modifiedAt
        }?.highlights ?? AccountFilters()
    }
    public var rules: [FilterRule] {
        let latest = filterRevisions?.filter { $0.membershipVersion == 1 }.max {
            $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt < $1.modifiedAt
        }
        return latest?.orderedRules ?? [.blockedDefault]
    }

    public var preferredUsers: Set<String> { Set(current.filter { $0.isPreferred == true }.map(\.username)) }
    public var policy: FilterPolicy { FilterPolicy(blocked: blockedUsers, accounts: accountFilters, preferred: preferredUsers, highlights: highlightFilters, rules: rules) }
    public var revisionCount: Int { revisions.count + (filterRevisions?.count ?? 0) }

    public init(revisions: [PersonRevision] = []) { self.revisions = revisions }

    public var current: [PersonRevision] {
        Dictionary(grouping: revisions, by: \.username).values.compactMap { versions in
            versions.max(by: Self.older)
        }.sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }

    public var blockedUsers: Set<String> { Set(current.filter(\.isBlocked).map(\.username)) }

    public func history(for username: String) -> [PersonRevision] {
        revisions.filter { $0.username == username }.sorted { Self.older($1, $0) }
    }

    /// Leaves of the known revision graph. Parenting these preserves every
    /// concurrent branch without repeating the entire transitive ancestry.
    public func revisionHeads(for username: String) -> [UUID] {
        let versions = revisions.filter { $0.username == username }
        let parents = Set(versions.flatMap(\.parentIDs))
        return versions.map(\.id).filter { !parents.contains($0) }.sorted { $0.uuidString < $1.uuidString }
    }

    public mutating func merge(_ other: RecordArchive) throws {
        try other.validate()
        var byID = Dictionary(uniqueKeysWithValues: revisions.map { ($0.id, $0) })
        for revision in other.revisions {
            if let old = byID[revision.id], old != revision { throw ArchiveError.conflictingID }
            byID[revision.id] = revision
        }
        var rules = Dictionary(uniqueKeysWithValues: (filterRevisions ?? []).map { ($0.id, $0) })
        for revision in other.filterRevisions ?? [] {
            if let old = rules[revision.id], old != revision { throw ArchiveError.conflictingID }
            rules[revision.id] = revision
        }
        var candidate = self
        candidate.revisions = byID.values.sorted(by: Self.older)
        candidate.filterRevisions = Array(rules.values)
        try candidate.validate()
        self = candidate
    }

    public func validate() throws {
        guard formatVersion == 1 else { throw ArchiveError.unsupportedVersion }
        guard revisionCount <= 100_000 else { throw ArchiveError.tooLarge }
        var ids = Set<UUID>()
        for r in filterRevisions ?? [] {
            guard ids.insert(r.id).inserted, r.modifiedAt.timeIntervalSince1970.isFinite,
                  r.filters.isValid, r.highlights?.isValid != false,
                  (r.orderedRules?.count ?? 0) <= 10_000,
                  r.orderedRules?.allSatisfy(\.isValid) != false,
                  Set((r.orderedRules ?? []).map(\.id)).count == (r.orderedRules?.count ?? 0) else { throw ArchiveError.invalidRecord }
        }
        for r in revisions {
            guard Self.validUsername(r.username), r.note.utf8.count <= 100_000,
                  r.citations.count <= 200, r.parentIDs.count <= 100_000,
                  ids.insert(r.id).inserted,
                  r.modifiedAt.timeIntervalSince1970.isFinite,
                  r.createdAt.timeIntervalSince1970.isFinite,
                  r.citations.allSatisfy({ c in
                      Self.validCitationURL(c.url) && c.excerpt.utf8.count <= 200_000 &&
                      c.annotation.utf8.count <= 100_000 && c.context.utf8.count <= 10_000
                  }) else { throw ArchiveError.invalidRecord }
        }
    }

    /// Drop the empty profile placeholders made by the old open-panel capture path.
    /// Append revisions so original data remains recoverable in history.
    public mutating func removeLegacyProfilePlaceholders(device: String = "", now: Date = Date()) {
        for person in current {
            let kept = person.citations.filter { citation in
                guard citation.savedIntentionally != true,
                      citation.annotation.isEmpty, citation.excerpt.isEmpty,
                      citation.author == person.username,
                      citation.context == "Profile: \(person.username) | Hacker News",
                      let url = URLComponents(string: citation.url),
                      url.scheme == "https", url.host == "news.ycombinator.com", url.path == "/user",
                      url.queryItems == [URLQueryItem(name: "id", value: person.username)] else { return true }
                return false
            }
            guard kept.count != person.citations.count else { continue }
            var revision = PersonRevision(username: person.username, isBlocked: person.isBlocked,
                note: person.note, citations: kept, createdAt: person.createdAt, device: device,
                parentIDs: revisionHeads(for: person.username))
            revision.isPreferred = person.isPreferred
            revision.modifiedAt = max(now, person.modifiedAt.addingTimeInterval(0.001))
            revisions.append(revision)
        }
    }

    public static func validUsername(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 100 &&
        name.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-").contains($0) }
    }

    public static func validCitationURL(_ value: String) -> Bool {
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme), url.host != nil,
              url.user == nil, url.password == nil else { return false }
        return true
    }

    private static func older(_ lhs: PersonRevision, _ rhs: PersonRevision) -> Bool {
        if lhs.modifiedAt != rhs.modifiedAt { return lhs.modifiedAt < rhs.modifiedAt }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

public enum ArchiveError: LocalizedError {
    case unsupportedVersion, invalidRecord, tooLarge, conflictingID
    public var errorDescription: String? {
        switch self {
        case .unsupportedVersion: "This backup uses an unsupported format."
        case .invalidRecord: "The record contains invalid or oversized data. Nothing was imported."
        case .tooLarge: "This backup is too large."
        case .conflictingID: "Two different revisions have the same identifier. Nothing was imported."
        }
    }
}

extension PersonRevision {
    public var hasSavedNotes: Bool {
        !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !citations.isEmpty
    }
    public var savedNotePreview: String {
        ([note] + citations.map(\.annotation) + citations.map(\.context))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? "Saved reference"
    }
    public func matchesSavedNotesSearch(_ query: String) -> Bool {
        let term = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return term.isEmpty || ([username, note] + citations.flatMap { [$0.annotation, $0.context, $0.excerpt, $0.url] })
            .contains { $0.localizedCaseInsensitiveContains(term) }
    }
}
