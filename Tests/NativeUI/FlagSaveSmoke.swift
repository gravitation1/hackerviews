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
        let reloaded = RecordStore(directory: directory)
        precondition(reloaded.archive.rules[0].assignedUsers.contains("example"))
        precondition(reloaded.archive.rules[0].itemIDs?.contains(123) != true, "User flags must not become item assignments")
        precondition(reloaded.current("example")?.citations.first?.excerpt == "Evidence")
        precondition(reloaded.current("example")?.note == "Existing personal note")
        print("PASS: dismissal saves nothing; failure is atomic; user assignment and evidence persist together")
    }
}
