import SwiftUI
#if os(macOS)
import AppKit

struct AccountNotesEditor: NSViewRepresentable {
    @Binding var text: String
    var placeholder = "What would you like to remember?"
    var focusOnAppear = false
    var onBlur: () -> Void = {}
    func makeCoordinator() -> Coordinator { Coordinator(text: $text, onBlur: onBlur) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        let editor = NotesTextView()
        editor.placeholder = placeholder
        editor.focusWhenAttached = focusOnAppear
        editor.isRichText = false
        editor.drawsBackground = false
        editor.font = .systemFont(ofSize: 14)
        editor.textColor = .labelColor
        editor.insertionPointColor = .labelColor
        editor.alignment = .left
        editor.textContainerInset = NSSize(width: 4, height: 6)
        editor.isVerticallyResizable = true
        editor.isHorizontallyResizable = false
        editor.autoresizingMask = [.width]
        editor.textContainer?.widthTracksTextView = true
        editor.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        editor.delegate = context.coordinator
        editor.setAccessibilityLabel(placeholder)
        scroll.documentView = editor
        return scroll
    }
    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.text = $text
        context.coordinator.onBlur = onBlur
        guard let editor = scroll.documentView as? NotesTextView else { return }
        editor.placeholder = placeholder
        if editor.string != text { editor.string = text }
        editor.needsDisplay = true
    }
    @MainActor final class Coordinator: NSObject, NSTextViewDelegate {
        var text: Binding<String>
        var onBlur: () -> Void
        init(text: Binding<String>, onBlur: @escaping () -> Void) { self.text = text; self.onBlur = onBlur }
        func textDidEndEditing(_ notification: Notification) { onBlur() }
        func textDidChange(_ notification: Notification) {
            guard let editor = notification.object as? NSTextView else { return }
            text.wrappedValue = editor.string
            editor.needsDisplay = true
        }
    }
}

final class NotesTextView: NSTextView {
    var placeholder = "What would you like to remember?"
    var focusWhenAttached = false
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, focusWhenAttached else { return }
        focusWhenAttached = false
        Task { @MainActor [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard string.isEmpty else { return }
        var origin = textContainerOrigin
        origin.x += textContainer?.lineFragmentPadding ?? 0
        (placeholder as NSString).draw(at: origin, withAttributes: [
            .font: font ?? NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.placeholderTextColor
        ])
    }
}
#else
struct AccountNotesEditor: View {
    @Binding var text: String
    var placeholder = "What would you like to remember?"
    var focusOnAppear = false
    var onBlur: () -> Void = {}
    @FocusState private var focused: Bool
    var body: some View {
        TextEditor(text: $text).scrollContentBackground(.hidden)
            .focused($focused)
            .onChange(of: focused) { _, editing in if !editing { onBlur() } }
            .onAppear { if focusOnAppear { focused = true } }
            .overlay(alignment: .topLeading) {
                if text.isEmpty {
                    Text(placeholder)
                        .foregroundStyle(.tertiary).padding(.leading, 5).padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .accessibilityLabel(placeholder)
    }
}
#endif
