#if os(macOS)
import AppKit
import SwiftUI

struct FilterNameField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let active: Bool
    let accessibilityName: String
    var coalescesEdits = false

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> SelectAllNameField {
        let field = SelectAllNameField()
        field.alignment = .left
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
        if field.currentEditor() == nil && field.stringValue != text { field.stringValue = text }
        field.placeholderString = placeholder
        field.textColor = active ? .labelColor : .secondaryLabelColor
        field.setAccessibilityLabel(accessibilityName)
        field.toolTip = "Click to rename; changes save automatically"
    }
    static func dismantleNSView(_ field: SelectAllNameField, coordinator: Coordinator) {
        coordinator.commit()
    }
    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: FilterNameField
        var pending: String?
        var saveTask: Task<Void, Never>?
        init(_ parent: FilterNameField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            guard parent.coalescesEdits else { parent.text = field.stringValue; return }
            pending = field.stringValue
            saveTask?.cancel()
            saveTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
                self?.commit()
            }
        }
        func controlTextDidEndEditing(_ notification: Notification) { commit() }
        func commit() {
            saveTask?.cancel(); saveTask = nil
            guard let value = pending else { return }
            pending = nil
            if parent.text != value { parent.text = value }
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
