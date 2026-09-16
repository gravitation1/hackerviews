import SwiftUI

@MainActor
final class RecordStore: ObservableObject {
    @Published private(set) var archive = RecordArchive()
    @Published var error: String?
    @Published private(set) var syncStatus = "Saved on this device"
    @Published private(set) var isSyncing = false
    @Published private(set) var storageAvailable = true
    private let fileURL: URL
    private let sync = CloudSync()
    private var readFailed = false
    var people: [PersonRevision] { archive.current }
    var blocked: Set<String> { archive.blockedUsers }
    var cloudEnabled: Bool { CloudSync.isConfigured }

    init(directory: URL? = nil) {
        let folder = directory ?? URL.applicationSupportDirectory.appendingPathComponent("QuietHN", isDirectory: true)
        fileURL = folder.appendingPathComponent("records.json")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                let loaded = try JSONDecoder().decode(RecordArchive.self, from: Data(contentsOf: fileURL))
                try loaded.validate()
                archive = loaded
                var cleaned = loaded
                cleaned.removeLegacyProfilePlaceholders(device: Self.deviceName)
                if cleaned.revisionCount != loaded.revisionCount { try persist(cleaned) }
            }
        } catch {
            readFailed = true
            storageAvailable = false
            self.error = "Could not read your records. The existing file has been preserved. \(error.localizedDescription)"
        }
        if cloudEnabled { syncStatus = "iCloud sync pending" }
    }

    func current(_ username: String) -> PersonRevision? { people.first { $0.username == username } }

    @discardableResult
    func save(username: String, blocked: Bool, note: String, citations: [Citation], preferred: Bool? = nil) -> Bool {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = archive.history(for: name)
        var revision = PersonRevision(username: name, isBlocked: blocked, note: note, citations: citations,
                                      createdAt: history.last?.createdAt ?? Date(), device: Self.deviceName,
                                      parentIDs: history.map(\.id))
        revision.isPreferred = preferred ?? current(name)?.isPreferred
        // A restored/imported future timestamp must not prevent a local edit from taking effect.
        revision.modifiedAt = max(Date(), (history.first?.modifiedAt ?? .distantPast).addingTimeInterval(0.001))
        do {
            var candidate = archive
            try candidate.merge(RecordArchive(revisions: [revision]))
            try persist(candidate)
            Task { await synchronize() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func saveRules(_ rules: [FilterRule]) -> Bool {
        guard rules != archive.rules else { return true }
        var candidate = archive
        var revision = AccountFilterRevision(filters: archive.accountFilters)
        revision.highlights = archive.highlightFilters
        revision.orderedRules = rules
        revision.membershipVersion = 1
        let latest = candidate.filterRevisions?.map(\.modifiedAt).max() ?? .distantPast
        revision.modifiedAt = max(Date(), latest.addingTimeInterval(0.001))
        candidate.filterRevisions = (candidate.filterRevisions ?? []) + [revision]
        do { try persist(candidate); Task { await synchronize() }; return true }
        catch { self.error = error.localizedDescription; return false }
    }

    @discardableResult
    func saveFilters(_ filters: AccountFilters, highlighting: Bool = false) -> Bool {
        var candidate = archive
        var revision = AccountFilterRevision(filters: highlighting ? archive.accountFilters : filters)
        revision.highlights = highlighting ? filters : archive.highlightFilters
        revision.orderedRules = archive.filterRevisions?.max { $0.modifiedAt < $1.modifiedAt }?.orderedRules
        let latest = candidate.filterRevisions?.map(\.modifiedAt).max() ?? .distantPast
        revision.modifiedAt = max(Date(), latest.addingTimeInterval(0.001))
        candidate.filterRevisions = (candidate.filterRevisions ?? []) + [revision]
        do {
            try persist(candidate)
            Task { await synchronize() }
            return true
        } catch { self.error = error.localizedDescription; return false }
    }

    func toggle(_ person: PersonRevision) {
        save(username: person.username, blocked: !person.isBlocked, note: person.note, citations: person.citations)
    }

    func restore(_ revision: PersonRevision) {
        save(username: revision.username, blocked: revision.isBlocked, note: revision.note, citations: revision.citations, preferred: revision.isPreferred ?? false)
    }

    func importBackup(_ data: Data) {
        do {
            guard data.count <= 50_000_000 else { throw ArchiveError.tooLarge }
            let incoming = try JSONDecoder().decode(RecordArchive.self, from: data)
            if readFailed {
                try incoming.validate()
                try recover(incoming)
                Task { await synchronize() }
                return
            }
            var candidate = archive
            try candidate.merge(incoming)
            try persist(candidate)
            Task { await synchronize() }
        } catch { self.error = error.localizedDescription }
    }

    func restoreRecoveryCopy() {
        do {
            let data = try Data(contentsOf: fileURL.appendingPathExtension("previous"))
            let recovery = try JSONDecoder().decode(RecordArchive.self, from: data)
            try recovery.validate()
            try recover(recovery)
        } catch { self.error = "Recovery failed. Import a valid backup instead. \(error.localizedDescription)" }
    }

    private func recover(_ recovery: RecordArchive) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(recovery)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let original = try Data(contentsOf: fileURL)
            try original.write(to: fileURL.appendingPathExtension("unreadable-\(UUID())"), options: .atomic)
        }
        try data.write(to: fileURL, options: .atomic)
        readFailed = false; archive = recovery; storageAvailable = true; error = nil
    }

    func synchronize() async {
        guard cloudEnabled, !isSyncing, !readFailed else { return }
        isSyncing = true
        syncStatus = "Syncing with iCloud…"
        defer { isSyncing = false }
        do {
            // Repeat if a local edit arrives while the network operation is suspended.
            var count: Int
            repeat {
                let snapshot = archive
                count = snapshot.revisionCount
                let remote = try await sync.exchange(snapshot)
                var candidate = archive
                try candidate.merge(remote)
                try persist(candidate)
            } while count != archive.revisionCount
            syncStatus = "Synced with iCloud · \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            syncStatus = "Saved locally · Sync unavailable: \(error.localizedDescription)"
        }
    }

    private func persist(_ value: RecordArchive) throws {
        guard !readFailed else { throw CocoaError(.fileReadCorruptFile) }
        try value.validate()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        // Maintain the previous successfully saved journal as a recovery file.
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let old = try Data(contentsOf: fileURL)
            try old.write(to: fileURL.appendingPathExtension("previous"), options: .atomic)
        }
        try data.write(to: fileURL, options: .atomic)
        archive = value
    }

    private static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone / iPad"
        #endif
    }
}
