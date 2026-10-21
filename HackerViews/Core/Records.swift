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
    public var effectiveFilterRevision: AccountFilterRevision? {
        filterRevisions?.filter { $0.membershipVersion == 1 }.max {
            $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt < $1.modifiedAt
        }
    }
    public var rules: [FilterRule] { effectiveFilterRevision?.orderedRules ?? [.blockedDefault] }
    /// The latest revision that carries link rewrites. A revision written by
    /// an app that knew nothing of them leaves the previous set in force.
    public var linkRewrites: [LinkRewrite] {
        filterRevisions?.filter { $0.linkRewrites != nil }.max {
            $0.modifiedAt == $1.modifiedAt ? $0.id.uuidString < $1.id.uuidString : $0.modifiedAt < $1.modifiedAt
        }?.linkRewrites ?? []
    }

    public var preferredUsers: Set<String> { Set(latest.filter { $0.isPreferred == true }.map(\.username)) }
    public var policy: FilterPolicy {
        let people = latest
        return FilterPolicy(blocked: Set(people.filter(\.isBlocked).map(\.username)), accounts: accountFilters,
                            preferred: Set(people.filter { $0.isPreferred == true }.map(\.username)),
                            highlights: highlightFilters, rules: rules, linkRewrites: linkRewrites)
    }
    public var revisionCount: Int { revisions.count + (filterRevisions?.count ?? 0) }

    public init(revisions: [PersonRevision] = []) { self.revisions = revisions }

    public var current: [PersonRevision] {
        latest.sorted { $0.username.localizedStandardCompare($1.username) == .orderedAscending }
    }
    /// Everyone's latest revision, in no particular order.
    private var latest: some Collection<PersonRevision> {
        var newest: [String: PersonRevision] = [:]
        for revision in revisions where newest[revision.username].map({ Self.older($0, revision) }) ?? true {
            newest[revision.username] = revision
        }
        return newest.values
    }

    /// The latest revision for one person, without building the whole list.
    public func current(for username: String) -> PersonRevision? {
        revisions.filter { $0.username == username }.max(by: Self.older)
    }

    public var blockedUsers: Set<String> { Set(latest.filter(\.isBlocked).map(\.username)) }

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

    /// Checks every record, or with `previous`, an archive already checked,
    /// only the records it does not hold unchanged, so a save costs what it adds.
    public func validate(since previous: RecordArchive? = nil) throws {
        guard formatVersion == 1 else { throw ArchiveError.unsupportedVersion }
        guard revisionCount <= 100_000 else { throw ArchiveError.tooLarge }
        let checkedFilters = Dictionary((previous?.filterRevisions ?? []).map { ($0.id, $0) }) { first, _ in first }
        let checkedPeople = Dictionary((previous?.revisions ?? []).map { ($0.id, $0) }) { first, _ in first }
        var ids = Set<UUID>()
        for r in filterRevisions ?? [] {
            guard ids.insert(r.id).inserted else { throw ArchiveError.invalidRecord }
            if checkedFilters[r.id] == r { continue }
            guard r.modifiedAt.timeIntervalSince1970.isFinite,
                  r.filters.isValid, r.highlights?.isValid != false,
                  (r.orderedRules?.count ?? 0) <= 10_000,
                  r.orderedRules?.allSatisfy(\.isValid) != false,
                  Set((r.orderedRules ?? []).map(\.id)).count == (r.orderedRules?.count ?? 0),
                  (r.linkRewrites?.count ?? 0) <= 1_000,
                  r.linkRewrites?.allSatisfy({ $0.from.utf8.count <= 2_000 && $0.to.utf8.count <= 2_000 }) != false,
                  Set((r.linkRewrites ?? []).map(\.id)).count == (r.linkRewrites?.count ?? 0) else { throw ArchiveError.invalidRecord }
        }
        for r in revisions {
            guard ids.insert(r.id).inserted else { throw ArchiveError.invalidRecord }
            if checkedPeople[r.id] == r { continue }
            guard Self.validUsername(r.username), r.note.utf8.count <= 100_000,
                  r.citations.count <= 200, r.parentIDs.count <= 100_000,
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
        !name.isEmpty && name.utf8.count <= 100 && name.utf8.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte) || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ||
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte) || byte == UInt8(ascii: "_") || byte == UInt8(ascii: "-")
        }
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

/// The newest thing saved about a person, for the preview on their name.
public struct LatestNote: Equatable, Sendable {
    public var text: String
    /// The saved reference's permalink, title and captured text; empty for the profile note.
    public var url = "", title = "", excerpt = ""
    public var date: Date
    /// How many other notes and references the person has.
    public var others: Int
}

extension RecordArchive {
    /// The person's newest saved reference, or their profile note when it was
    /// last written after that reference was saved.
    public func latestNote(for username: String) -> LatestNote? {
        guard let person = current(for: username) else { return nil }
        let note = person.note.trimmingCharacters(in: .whitespacesAndNewlines)
        let total = person.citations.count + (note.isEmpty ? 0 : 1)
        guard total > 0 else { return nil }
        var noteDate = person.modifiedAt
        if !note.isEmpty {
            for revision in history(for: username) {
                guard revision.note == person.note else { break }
                noteDate = revision.modifiedAt
            }
        }
        let citation = person.citations.max { $0.capturedAt < $1.capturedAt }
        if let citation, note.isEmpty || citation.capturedAt >= noteDate {
            return LatestNote(text: citation.annotation.trimmingCharacters(in: .whitespacesAndNewlines),
                              url: citation.url, title: citation.context, excerpt: citation.excerpt,
                              date: citation.capturedAt, others: total - 1)
        }
        return LatestNote(text: note, date: noteDate, others: total - 1)
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
