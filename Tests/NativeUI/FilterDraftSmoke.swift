import SwiftUI
import AppKit

@main struct FilterDraftSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RecordStore(directory: directory)
        let before = try! JSONEncoder().encode(store.archive)
        let id = UUID().uuidString
        let host = NSHostingView(rootView: FilterEditor(store: store, id: id))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 640, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        Task { @MainActor in
            var savedName = "Original"
            var commits = 0
            let nameControl = FilterNameField(text: Binding(get: { savedName }, set: { savedName = $0; commits += 1 }),
                                             placeholder: "Name", active: true, accessibilityName: "Name", coalescesEdits: true)
            let coordinator = nameControl.makeCoordinator()
            let input = NSTextField()
            for name in ["N", "Ne", "New name"] {
                input.stringValue = name
                coordinator.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: input))
            }
            precondition(commits == 0, "Typing must not create a revision per character")
            coordinator.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: input))
            precondition(savedName == "New name" && commits == 1, "Leaving the field must commit immediately")
            try? await Task.sleep(for: .milliseconds(1100))
            precondition(commits == 1, "Cancelled idle task must not duplicate the commit")
            print("PASS filter name edits coalesce and commit on editing completion")
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            @MainActor func find(_ view: NSView) -> SelectAllNameField? {
                if let field = view as? SelectAllNameField { return field }
                return view.subviews.compactMap { find($0) }.first
            }
            guard let field = find(host) else { fatalError("Missing filter name input") }
            for character in "Draft filter" {
                field.stringValue.append(character)
                field.delegate?.controlTextDidChange?(Notification(name: NSControl.textDidChangeNotification, object: field))
                try? await Task.sleep(for: .milliseconds(30))
                precondition(!store.archive.rules.contains { $0.id == id }, "Typing must not create a filter")
            }
            window.contentView = NSView()
            try? await Task.sleep(for: .milliseconds(100))
            // Compare decoded values; JSON object key ordering is not stable.
            let original = try! JSONDecoder().decode(RecordArchive.self, from: before)
            precondition(store.archive.filterRevisions == original.filterRevisions, "Discarding must not append history")
            precondition(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("records.json").path))
            try? FileManager.default.removeItem(at: directory)
            print("PASS new filter: typing and dismissing leave rules, history, and disk unchanged")
            exit(0)
        }
        app.run()
    }
}
