import CloudKit
import CryptoKit
import Foundation

/// The token and everything downloaded through it are one atomic checkpoint.
/// Quarantined records retain their original CloudKit archive for recovery.
struct CloudSyncCheckpoint: Codable {
    var token: Data?
    var archive = RecordArchive()
    var known = Set<String>()
    var quarantined: [String: Data] = [:]

    mutating func ingest(_ record: CKRecord) throws {
        let name = record.recordID.recordName
        do {
            guard let data = record["payload"] as? Data else { throw ArchiveError.invalidRecord }
            var incoming = RecordArchive()
            switch record.recordType {
            case "PersonRevision":
                let revision = try JSONDecoder().decode(PersonRevision.self, from: data)
                guard revision.id.uuidString == name else { throw ArchiveError.invalidRecord }
                incoming.revisions = [revision]
            case "AccountFilterRevision":
                let revision = try JSONDecoder().decode(AccountFilterRevision.self, from: data)
                guard revision.id.uuidString == name else { throw ArchiveError.invalidRecord }
                incoming.filterRevisions = [revision]
            default: throw ArchiveError.unsupportedVersion
            }
            var candidate = archive
            try candidate.merge(incoming)
            archive = candidate
            quarantined.removeValue(forKey: name)
        } catch {
            // Failure to preserve the original is fatal: never advance past lost data.
            quarantined[name] = try NSKeyedArchiver.archivedData(withRootObject: record, requiringSecureCoding: true)
        }
        known.insert(name)
    }
}

/// Synchronous invalidation prevents a queued actor task from reusing an old
/// account identity after CloudKit posts its account-change notification.
final class CloudAccountIdentityCache: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var identities: [String: String] = [:]
    private var observer: NSObjectProtocol?
    init() {
        observer = NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: nil) { [weak self] _ in
            self?.invalidate()
        }
    }
    deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    func invalidate() {
        lock.lock(); defer { lock.unlock() }
        generation += 1; identities.removeAll()
    }
    func snapshot(_ container: String) -> (Int, String?) {
        lock.lock(); defer { lock.unlock() }
        return (generation, identities[container])
    }
    func remember(_ name: String, container: String, generation expected: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard generation == expected else { return false }
        identities[container] = name
        return true
    }
}

/// Private, append-only CloudKit records. No HN credentials enter this service.
actor CloudSync {
    static var isConfigured: Bool { Bundle.main.object(forInfoDictionaryKey: "HackerViewsCloudEnabled") as? String == "YES" }
    private(set) var warning: String?
    private let identities = CloudAccountIdentityCache()

    func exchange(_ local: RecordArchive) async throws -> RecordArchive {
        guard Self.isConfigured else { return RecordArchive() }
        let identifier = Bundle.main.object(forInfoDictionaryKey: "HackerViewsCloudContainer") as? String ?? "iCloud.com.local.HackerViews"
        let container = CKContainer(identifier: identifier)
        guard try await container.accountStatus() == .available else { identities.invalidate(); throw SyncError.noAccount }
        let (generation, cachedAccount) = identities.snapshot(identifier)
        let account: String
        if let cachedAccount { account = cachedAccount }
        else {
            account = try await container.userRecordID().recordName
            guard identities.remember(account, container: identifier, generation: generation) else { throw SyncError.accountChanged }
        }
        let scope = SHA256.hash(data: Data((identifier + "\n" + account + "\nHackerViews").utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask,
                                                   appropriateFor: nil, create: true)
            .appendingPathComponent("HackerViews/cloud-sync", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(scope + ".json")
        var state = CloudSyncCheckpoint()
        if FileManager.default.fileExists(atPath: file.path) {
            state = try JSONDecoder().decode(CloudSyncCheckpoint.self, from: Data(contentsOf: file))
            try state.archive.validate()
        }
        let database = container.privateCloudDatabase
        let zoneID = CKRecordZone.ID(zoneName: "HackerViews", ownerName: CKCurrentUserDefaultName)
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        do {
            try await fetchChanges(database: database, zone: zoneID, state: &state, file: file, identifier: identifier, generation: generation)
        } catch let error as CKError where error.code == .changeTokenExpired {
            // A complete scan establishes a new baseline; keep prior quarantined data.
            let preserved = state.quarantined
            state = CloudSyncCheckpoint()
            state.quarantined = preserved
            try await fetchChanges(database: database, zone: zoneID, state: &state, file: file, identifier: identifier, generation: generation)
        }
        warning = state.quarantined.isEmpty ? nil :
            "iCloud sync skipped \(state.quarantined.count) unreadable record(s). Originals are preserved in \(file.path). Some remote edits may be missing."
        let pending: [(UUID, String, Data)] = try local.revisions.filter { !state.known.contains($0.id.uuidString) }.map {
            ($0.id, "PersonRevision", try JSONEncoder().encode($0))
        } + (local.filterRevisions ?? []).filter { !state.known.contains($0.id.uuidString) }.map {
            ($0.id, "AccountFilterRevision", try JSONEncoder().encode($0))
        }
        for start in stride(from: 0, to: pending.count, by: 100) {
            let batch = pending[start..<min(start + 100, pending.count)]
            let records = try batch.map { revision in
                let record = CKRecord(recordType: revision.1, recordID: .init(recordName: revision.0.uuidString, zoneID: zoneID))
                guard revision.2.count < 900_000 else { throw SyncError.tooLarge }
                record["payload"] = revision.2 as CKRecordValue
                return record
            }
            try checkAccount(identifier, generation: generation)
            let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .ifServerRecordUnchanged, atomically: true)
            try checkAccount(identifier, generation: generation)
            for (_, outcome) in result.saveResults { try state.ingest(outcome.get()) }
            try JSONEncoder().encode(state).write(to: file, options: .atomic)
        }
        return state.archive
    }

    private func checkAccount(_ identifier: String, generation: Int) throws {
        guard identities.snapshot(identifier).0 == generation else { throw SyncError.accountChanged }
    }

    private func fetchChanges(database: CKDatabase, zone: CKRecordZone.ID,
                              state: inout CloudSyncCheckpoint, file: URL, identifier: String, generation: Int) async throws {
        var token = try state.token.map {
            try NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        } ?? nil
        var more = true
        while more {
            try checkAccount(identifier, generation: generation)
            let result = try await database.recordZoneChanges(inZoneWith: zone, since: token)
            try checkAccount(identifier, generation: generation)
            for (_, outcome) in result.modificationResultsByID {
                // Transport failures are retried; only unreadable record content is quarantined.
                try state.ingest(outcome.get().record)
            }
            for deletion in result.deletions { state.known.remove(deletion.recordID.recordName) }
            let tokenChanged = token?.isEqual(result.changeToken) != true
            token = result.changeToken
            if tokenChanged || !result.modificationResultsByID.isEmpty || !result.deletions.isEmpty {
                state.token = try token.map { try NSKeyedArchiver.archivedData(withRootObject: $0, requiringSecureCoding: true) }
                try JSONEncoder().encode(state).write(to: file, options: .atomic)
            }
            more = result.moreComing
        }
    }
}

private enum SyncError: LocalizedError {
    case noAccount, tooLarge, accountChanged
    var errorDescription: String? {
        switch self {
        case .accountChanged: "The iCloud account changed during sync. The next sync will retry with the current account."
        case .noAccount: "Sign in to iCloud in System Settings to synchronize your records."
        case .tooLarge: "A record is too large for iCloud. It remains saved locally and exportable."
        }
    }
}
