import SwiftUI
import AppKit

@main struct FlagSaveSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = RecordStore(directory: directory)
        let source = Citation(url: "https://news.ycombinator.com/item?id=123", author: "example", excerpt: "Evidence", context: "Comment")
        let before = store.archive.revisionCount
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 640), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: RecordEditor(store: store, draft: RecordDraft(username: "example", citation: source)))
        window.contentView?.layoutSubtreeIfNeeded()
        window.contentView = NSView()
        precondition(store.archive.revisionCount == before, "Opening and dismissing must not save evidence")
        var rules = store.archive.rules
        rules[0].assignedUsers.insert("example")
        var invalid = source
        invalid.url = "javascript:invalid"
        precondition(!store.save(username: "example", blocked: false, note: "", citations: [invalid], rules: rules))
        precondition(store.archive.revisionCount == before, "Failed evidence validation must not apply the filter")
        precondition(store.current("example") == nil)
        precondition(store.save(username: "example", blocked: false, note: "Existing personal note", citations: [source], rules: rules))
        let base = try! JSONDecoder().decode(RecordArchive.self, from: Data(contentsOf: directory.appendingPathComponent("records.json")))
        precondition(base.revisionCount == 0, "Save must not rewrite the complete snapshot on the main thread")
        let reloaded = RecordStore(directory: directory)
        precondition(reloaded.archive.rules[0].assignedUsers.contains("example"))
        precondition(reloaded.archive.rules[0].itemIDs?.contains(123) != true, "User flags must not become item assignments")
        precondition(reloaded.current("example")?.citations.first?.excerpt == "Evidence")
        precondition(reloaded.current("example")?.note == "Existing personal note")
        store.flushJournal()
        let checkpointed = RecordStore(directory: directory)
        precondition(checkpointed.current("example") == reloaded.current("example"))
        let transactions = try! FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("record-transactions"), includingPropertiesForKeys: nil)
        precondition(transactions.isEmpty, "Checkpoint removes only incorporated transactions")
        precondition(store.save(username: "example", blocked: false, note: "Later note", citations: [source]))
        store.flushJournal()
        try! Data("corrupt".utf8).write(to: directory.appendingPathComponent("records.json"))
        let damaged = RecordStore(directory: directory)
        precondition(!damaged.storageAvailable)
        damaged.restoreRecoveryCopy()
        precondition(damaged.storageAvailable && damaged.current("example")?.note == "Existing personal note")
        let interrupted = directory.appendingPathComponent("interrupted")
        let pending = interrupted.appendingPathComponent("record-transactions")
        try! FileManager.default.createDirectory(at: pending, withIntermediateDirectories: true)
        try! Data("corrupt".utf8).write(to: interrupted.appendingPathComponent("records.json"))
        try! JSONEncoder().encode(RecordArchive()).write(to: interrupted.appendingPathComponent("records.json.previous"))
        try! JSONEncoder().encode(store.archive).write(to: pending.appendingPathComponent("transaction.json"))
        let interruptedStore = RecordStore(directory: interrupted)
        precondition(!interruptedStore.storageAvailable)
        interruptedStore.restoreRecoveryCopy()
        precondition(interruptedStore.current("example")?.note == "Later note", "Recovery must replay durable transactions not yet checkpointed")
        print("PASS recovery replays pending transactions after snapshot corruption")
        print("PASS checkpoint recovery copy preserves the previous valid snapshot")
        print("PASS durable transaction replay before checkpoint and equivalent checkpoint reload")
        print("PASS: dismissal saves nothing; failure is atomic; user assignment and evidence persist together")
    }
}
