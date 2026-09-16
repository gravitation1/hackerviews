#if os(macOS)
import AppKit
import SwiftUI

struct FilterNameField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let active: Bool
    let accessibilityName: String

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SelectAllNameField {
        let field = SelectAllNameField()
        field.isEditable = true
        field.isSelectable = true
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        field.delegate = context.coordinator
        field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNSView(field, context: context)
        return field
    }
    func updateNSView(_ field: SelectAllNameField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.textColor = active ? .labelColor : .secondaryLabelColor
        field.setAccessibilityLabel(accessibilityName)
        field.toolTip = "Click to rename; changes save automatically"
    }
    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilterNameField
        init(_ parent: FilterNameField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
    }
}

final class SelectAllNameField: NSTextField {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        let wasEditing = currentEditor() != nil
        super.mouseDown(with: event)
        if !wasEditing { currentEditor()?.selectAll(nil) }
    }
}
#endif
