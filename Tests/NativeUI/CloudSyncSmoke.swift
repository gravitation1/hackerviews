import CloudKit
import Foundation

@main struct CloudSyncSmoke {
    static func main() throws {
        func record(_ revision: PersonRevision) throws -> CKRecord {
            let record = CKRecord(recordType: "PersonRevision", recordID: .init(recordName: revision.id.uuidString))
            record["payload"] = try JSONEncoder().encode(revision) as CKRecordValue
            return record
        }
        let identity = CloudAccountIdentityCache()
        let (generation, empty) = identity.snapshot("test")
        precondition(empty == nil)
        precondition(identity.remember("alice", container: "test", generation: generation))
        precondition(identity.snapshot("test").1 == "alice")
        NotificationCenter.default.post(name: .CKAccountChanged, object: nil)
        precondition(identity.snapshot("test").1 == nil)
        precondition(!identity.remember("stale", container: "test", generation: generation))
        print("PASS account-change notification invalidates cached and in-flight identities")
        let first = PersonRevision(username: "alice", isBlocked: true, note: "Keep this", citations: [])
        let second = PersonRevision(username: "bob", isBlocked: false, note: "Later page", citations: [])
        var state = CloudSyncCheckpoint()
        try state.ingest(record(first))
        let bad = CKRecord(recordType: "PersonRevision", recordID: .init(recordName: UUID().uuidString))
        bad["payload"] = Data("broken".utf8) as CKRecordValue
        try state.ingest(bad)
        try state.ingest(record(second))
        state.token = Data("opaque checkpoint token".utf8)
        let data = try JSONEncoder().encode(state)
        var restored = try JSONDecoder().decode(CloudSyncCheckpoint.self, from: data)
        precondition(restored.token == state.token && restored.archive.revisionCount == 2)
        precondition(restored.known.count == 3 && restored.quarantined.count == 1)
        let original = try NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: restored.quarantined[bad.recordID.recordName]!)!
        precondition(original["payload"] as? Data == Data("broken".utf8))
        try restored.ingest(record(first))
        precondition(restored.archive.revisionCount == 2, "Replayed pages must deduplicate")
        var conflicting = first
        conflicting.note = "Attempted overwrite"
        try restored.ingest(record(conflicting))
        precondition(restored.archive.revisions.first(where: { $0.id == first.id })?.note == "Keep this")
        precondition(restored.quarantined[first.id.uuidString] != nil)
        try restored.ingest(record(first))
        precondition(restored.quarantined[first.id.uuidString] == nil)
        let mismatch = try record(second)
        mismatch["payload"] = try JSONEncoder().encode(first) as CKRecordValue
        try restored.ingest(mismatch)
        precondition(restored.quarantined[second.id.uuidString] != nil)
        print("PASS incremental checkpoint retains records, token and known IDs; corrupt/conflicting/mismatched records preserved; replay deduplicates")
    }
}
