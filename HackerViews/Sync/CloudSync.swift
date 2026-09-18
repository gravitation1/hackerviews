import CloudKit
import Foundation

/// Private, append-only CloudKit records. No HN credentials enter this service.
actor CloudSync {
    static var isConfigured: Bool { Bundle.main.object(forInfoDictionaryKey: "HackerViewsCloudEnabled") as? String == "YES" }

    func exchange(_ local: RecordArchive) async throws -> RecordArchive {
        guard Self.isConfigured else { return RecordArchive() }
        let identifier = Bundle.main.object(forInfoDictionaryKey: "HackerViewsCloudContainer") as? String ?? "iCloud.com.local.HackerViews"
        let container = CKContainer(identifier: identifier)
        guard try await container.accountStatus() == .available else { throw SyncError.noAccount }
        let database = container.privateCloudDatabase
        // A custom zone supports change enumeration without a queryable schema index.
        let zoneID = CKRecordZone.ID(zoneName: "HackerViews", ownerName: CKCurrentUserDefaultName)
        _ = try await database.save(CKRecordZone(zoneID: zoneID))
        let remote = try await fetchAll(database: database, zone: zoneID)
        let known = Set(remote.revisions.map(\.id))
        let knownFilters = Set((remote.filterRevisions ?? []).map(\.id))
        let pending: [(UUID, String, Data)] = try local.revisions.filter { !known.contains($0.id) }.map {
            ($0.id, "PersonRevision", try JSONEncoder().encode($0))
        } + (local.filterRevisions ?? []).filter { !knownFilters.contains($0.id) }.map {
            ($0.id, "AccountFilterRevision", try JSONEncoder().encode($0))
        }
        for start in stride(from: 0, to: pending.count, by: 100) {
            let batch = pending[start..<min(start + 100, pending.count)]
            let records = try batch.map { revision in
                let record = CKRecord(recordType: revision.1, recordID: .init(recordName: revision.0.uuidString, zoneID: zoneID))
                let payload = revision.2
                guard payload.count < 900_000 else { throw SyncError.tooLarge }
                record["payload"] = payload as CKRecordValue
                return record
            }
            let result = try await database.modifyRecords(saving: records, deleting: [], savePolicy: .allKeys, atomically: true)
            for (_, outcome) in result.saveResults { _ = try outcome.get() }
        }
        return remote
    }

    private func fetchAll(database: CKDatabase, zone: CKRecordZone.ID) async throws -> RecordArchive {
        var token: CKServerChangeToken?
        var revisions: [PersonRevision] = []
        var filters: [AccountFilterRevision] = []
        var more = true
        while more {
            let result = try await database.recordZoneChanges(inZoneWith: zone, since: token)
            for (_, outcome) in result.modificationResultsByID {
                let modification = try outcome.get()
                guard let data = modification.record["payload"] as? Data else { throw ArchiveError.invalidRecord }
                switch modification.record.recordType {
                case "PersonRevision": revisions.append(try JSONDecoder().decode(PersonRevision.self, from: data))
                case "AccountFilterRevision": filters.append(try JSONDecoder().decode(AccountFilterRevision.self, from: data))
                default: throw ArchiveError.unsupportedVersion
                }
            }
            token = result.changeToken
            more = result.moreComing
        }
        var archive = RecordArchive(revisions: revisions)
        archive.filterRevisions = filters
        try archive.validate()
        return archive
    }
}

private enum SyncError: LocalizedError {
    case noAccount, tooLarge
    var errorDescription: String? {
        switch self {
        case .noAccount: "Sign in to iCloud in System Settings to synchronize your records."
        case .tooLarge: "A record is too large for iCloud. It remains saved locally and exportable."
        }
    }
}
