import SwiftUI

@MainActor
final class RecordStore: ObservableObject {
    @Published private(set) var archive = RecordArchive()
    @Published var error: String?
    @Published private(set) var recoveryNotice: String?
    @Published private(set) var syncStatus = "Saved on this device"
    @Published private(set) var isSyncing = false
    @Published private(set) var storageAvailable = true
    private let fileURL: URL
    private let journal: RecordJournal
    private let sync = CloudSync()
    private var readFailed = false
    var people: [PersonRevision] { archive.current }
    var blocked: Set<String> { archive.blockedUsers }
    var cloudEnabled: Bool { CloudSync.isConfigured }

    init(directory: URL? = nil) {
        let folder = directory ?? URL.applicationSupportDirectory.appendingPathComponent("HackerViews", isDirectory: true)
        fileURL = folder.appendingPathComponent("records.json")
        journal = RecordJournal(file: fileURL)
        recoveryNotice = try? String(contentsOf: folder.appendingPathComponent("recovery-notice.txt"), encoding: .utf8)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: fileURL.path) {
                var loaded = try JSONDecoder().decode(RecordArchive.self, from: Data(contentsOf: fileURL))
                try journal.replay(into: &loaded)
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

    func acknowledgeRecoveryNotice() {
        let notice = fileURL.deletingLastPathComponent().appendingPathComponent("recovery-notice.txt")
        do {
            if FileManager.default.fileExists(atPath: notice.path) { try FileManager.default.removeItem(at: notice) }
            recoveryNotice = nil
        } catch { self.error = "Couldn’t dismiss the recovery notice: \(error.localizedDescription)" }
    }

    func current(_ username: String) -> PersonRevision? { people.first { $0.username == username } }

    @discardableResult
    func save(username: String, blocked: Bool, note: String, citations: [Citation], preferred: Bool? = nil, rules: [FilterRule]? = nil) -> Bool {
        let name = username.trimmingCharacters(in: .whitespacesAndNewlines)
        let history = archive.history(for: name)
        var revision = PersonRevision(username: name, isBlocked: blocked, note: note, citations: citations,
                                      createdAt: history.last?.createdAt ?? Date(), device: Self.deviceName,
                                      parentIDs: archive.revisionHeads(for: name))
        revision.isPreferred = preferred ?? current(name)?.isPreferred
        // A restored/imported future timestamp must not prevent a local edit from taking effect.
        revision.modifiedAt = max(Date(), (history.first?.modifiedAt ?? .distantPast).addingTimeInterval(0.001))
        do {
            var candidate = archive
            try candidate.merge(RecordArchive(revisions: [revision]))
            if let rules, rules != archive.rules {
                var filters = AccountFilterRevision(filters: archive.accountFilters)
                filters.highlights = archive.highlightFilters
                filters.orderedRules = rules
                filters.membershipVersion = 1
                filters.modifiedAt = max(Date(), (candidate.filterRevisions?.map(\.modifiedAt).max() ?? .distantPast).addingTimeInterval(0.001))
                candidate.filterRevisions = (candidate.filterRevisions ?? []) + [filters]
            }
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
        revision.orderedRules = archive.effectiveFilterRevision?.orderedRules
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
            var incoming = try JSONDecoder().decode(RecordArchive.self, from: data)
            if readFailed {
                try incoming.validate()
                let unreadable = try journal.replay(into: &incoming, allowUnreadable: true)
                try recover(incoming, unreadable: unreadable)
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
            var recovery = try JSONDecoder().decode(RecordArchive.self, from: data)
            let unreadable = try journal.replay(into: &recovery, allowUnreadable: true)
            try recovery.validate()
            try recover(recovery, unreadable: unreadable)
        } catch { self.error = "Recovery failed. Import a valid backup instead. \(error.localizedDescription)" }
    }

    private func recover(_ recovery: RecordArchive, unreadable: [URL] = []) throws {
        journal.flush()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(recovery)
        if FileManager.default.fileExists(atPath: fileURL.path) {
            let original = try Data(contentsOf: fileURL)
            try original.write(to: fileURL.appendingPathExtension("unreadable-\(UUID())"), options: .atomic)
        }
        try data.write(to: fileURL, options: .atomic)
        let preserved = try journal.retireDeltas()
        if !unreadable.isEmpty {
            let files = unreadable.map { original -> String in
                let url = preserved?.appendingPathComponent(original.lastPathComponent) ?? original
                let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
                return url.path + " (last modified " + (date?.formatted() ?? "unknown") + ")"
            }.joined(separator: "\n")
            let notice = "Recovery was incomplete. Edits in these unreadable transactions may be missing; affected records or filters may reflect an earlier revision. The original files are preserved:\n" + files
            try notice.write(to: fileURL.deletingLastPathComponent().appendingPathComponent("recovery-notice.txt"), atomically: true, encoding: .utf8)
            recoveryNotice = notice
        }
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
            syncStatus = await sync.warning ?? "Synced with iCloud · \(Date().formatted(date: .omitted, time: .shortened))"
        } catch {
            syncStatus = "Saved locally · Sync unavailable: \(error.localizedDescription)"
        }
    }

    private func persist(_ value: RecordArchive) throws {
        guard !readFailed else { throw CocoaError(.fileReadCorruptFile) }
        try value.validate()
        try journal.append(value, previous: archive)
        archive = value
    }

    func flushJournal() { journal.flush() }

    private static var deviceName: String {
        #if os(macOS)
        "Mac"
        #else
        "iPhone / iPad"
        #endif
    }
}


// Small immutable transactions are durable before save() succeeds. Full snapshots
// and recovery-copy I/O run on a utility queue; a crash can always replay deltas.
private final class RecordJournal: @unchecked Sendable {
    private let file: URL
    private let directory: URL
    private let queue = DispatchQueue(label: "HackerViews.record-checkpoints", qos: .utility)
    private var checkpoint: DispatchWorkItem?
    private var checkpointBody: (@Sendable () -> Void)?
    private var checkpointDeadline: DispatchTime?
    init(file: URL) {
        self.file = file
        directory = file.deletingLastPathComponent().appendingPathComponent("record-transactions")
    }
    @discardableResult
    func replay(into archive: inout RecordArchive, allowUnreadable: Bool = false) throws -> [URL] {
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        var unreadable: [URL] = []
        for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where url.pathExtension == "json" {
            do { try archive.merge(JSONDecoder().decode(RecordArchive.self, from: Data(contentsOf: url))) }
            catch {
                guard allowUnreadable else { throw error }
                unreadable.append(url)
            }
        }
        return unreadable
    }
    func append(_ value: RecordArchive, previous: RecordArchive) throws {
        let known = Set(previous.revisions.map(\.id))
        let knownFilters = Set((previous.filterRevisions ?? []).map(\.id))
        var delta = RecordArchive(revisions: value.revisions.filter { !known.contains($0.id) })
        delta.filterRevisions = value.filterRevisions?.filter { !knownFilters.contains($0.id) }
        guard delta.revisionCount > 0 else { return }
        let manager = FileManager.default
        // Establish a readable base before the first durable transaction.
        if !manager.fileExists(atPath: file.path) {
            let base = try JSONEncoder().encode(previous)
            try base.write(to: file, options: .atomic)
            try base.write(to: file.appendingPathExtension("previous"), options: .atomic)
        }
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let transaction = directory.appendingPathComponent(UUID().uuidString + ".json")
        try JSONEncoder().encode(delta).write(to: transaction, options: .atomic)
        let included = (try? manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        checkpoint?.cancel()
        let file = self.file
        let body: @Sendable () -> Void = {
            let manager = FileManager.default
            do {
                let data = try JSONEncoder().encode(value)
                if manager.fileExists(atPath: file.path) {
                    try Data(contentsOf: file).write(to: file.appendingPathExtension("previous"), options: .atomic)
                }
                try data.write(to: file, options: .atomic)
                // Only remove transactions incorporated in this snapshot. New saves
                // arriving during the write remain available for crash recovery.
                for url in included where url.pathExtension == "json" { try? manager.removeItem(at: url) }
            } catch {
                // The durable transactions remain authoritative if checkpointing fails.
            }
        }
        checkpointBody = body
        let work = DispatchWorkItem(block: body)
        checkpoint = work
        let now = DispatchTime.now()
        if checkpointDeadline == nil || checkpointDeadline! <= now { checkpointDeadline = now + 1 }
        // Continuous editing still checkpoints once per second, rather than
        // indefinitely postponing compaction until the user stops typing.
        queue.asyncAfter(deadline: checkpointDeadline!, execute: work)
    }
    func flush() {
        checkpoint?.cancel()
        let body = checkpointBody
        checkpointBody = nil
        queue.sync { body?() }
    }
    func retireDeltas() throws -> URL? {
        guard FileManager.default.fileExists(atPath: directory.path) else { return nil }
        let preserved = directory.appendingPathExtension("recovered-" + UUID().uuidString)
        try FileManager.default.moveItem(at: directory, to: preserved)
        return preserved
    }
}
