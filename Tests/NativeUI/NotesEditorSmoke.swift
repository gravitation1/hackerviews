import AppKit
import SwiftUI

@main struct NotesEditorSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var text = ""
        let binding = Binding(get: { text }, set: { text = $0 })
        let host = NSHostingView(rootView: AccountNotesEditor(text: binding, placeholder: "Add a note about this reference…", focusOnAppear: true).frame(width: 500, height: 96))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 96), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = host
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            host.layoutSubtreeIfNeeded()
            @MainActor func find(_ view: NSView) -> NotesTextView? {
                if let editor = view as? NotesTextView { return editor }
                return view.subviews.compactMap { find($0) }.first
            }
            guard let editor = find(host) else { fatalError("Missing native editor") }
            precondition(editor.alignment == .left)
            precondition(editor.placeholder == "Add a note about this reference…")
            precondition(window.firstResponder === editor, "New reference must focus its note editor")
            precondition((editor.textContainer?.containerSize.width ?? 0) > 400)
            let height = host.frame.height
            editor.insertText("First line", replacementRange: NSRange(location: 0, length: 0))
            editor.insertText("\nSecond line", replacementRange: editor.selectedRange())
            precondition(text == "First line\nSecond line")
            precondition(editor.selectedRange().location == text.utf16.count)
            host.layoutSubtreeIfNeeded()
            precondition(host.frame.height == height)
            print("PASS native notes: automatic focus, reference placeholder, left aligned, full width, multiline input, stable height and caret")
            exit(0)
        }
        app.run()
    }
}
