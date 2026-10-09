#if os(macOS)
import AppKit
import SwiftUI

/// The filters a user or contribution can be added to, as a native pop-up in
/// which a highlight filter's name is in its colour, as it is on the page and
/// in the table. SwiftUI's picker hands a Mac menu its items as plain strings,
/// which would drop the colour; owning the menu and its actions also keeps a
/// sheet's responder validation from disabling the choices, as the effect
/// picker does.
struct MacFilterPicker: NSViewRepresentable {
    @Binding var selection: String
    var rules: [FilterRule]
    var createID: String
    var accessibilityLabel: String

    struct Choice { var id: String; var title: NSAttributedString }
    /// Items in order: no filter, create, then every rule.
    static func choices(rules: [FilterRule], createID: String) -> [Choice] {
        [Choice(id: "", title: plain("No filter · Note only")), Choice(id: createID, title: plain("Create filter…"))]
            + rules.map { Choice(id: $0.id, title: title(for: $0)) }
    }
    private static var font: NSFont { .menuFont(ofSize: 0) }
    private static func plain(_ text: String) -> NSAttributedString { NSAttributedString(string: text, attributes: [.font: font]) }
    /// The name in the filter's colour when it highlights, fainter when paused,
    /// then the effect. The other runs carry no colour of their own, so the
    /// menu draws them as it draws any item: enabled, disabled or highlighted.
    static func title(for rule: FilterRule) -> NSAttributedString {
        let title = NSMutableAttributedString(string: rule.name, attributes: [.font: font])
        if let accent = rule.nameAccent {
            let color = rule.enabled ? accent.nsColor : accent.nsColor.withAlphaComponent(0.5)
            title.addAttribute(.foregroundColor, value: color, range: NSRange(location: 0, length: title.length))
        }
        title.append(plain(" · " + rule.choiceDetail))
        return title
    }
    func makeCoordinator() -> Coordinator { Coordinator(selection: $selection) }
    func makeNSView(context: Context) -> NSPopUpButton {
        let button = Self.makeButton(coordinator: context.coordinator)
        Self.refresh(button, coordinator: context.coordinator, rules: rules, createID: createID, selection: selection)
        return button
    }
    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.selection = $selection
        Self.refresh(button, coordinator: context.coordinator, rules: rules, createID: createID, selection: selection)
        button.setAccessibilityLabel(accessibilityLabel)
    }

    static func makeButton(coordinator: Coordinator) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        let menu = NSMenu(title: "Filter")
        menu.autoenablesItems = false
        button.menu = menu
        return button
    }
    /// Rebuilds the items when the filters changed, and shows the selection;
    /// the button's face takes the selected item's title, colour and all.
    static func refresh(_ button: NSPopUpButton, coordinator: Coordinator, rules: [FilterRule], createID: String, selection: String) {
        let choices = choices(rules: rules, createID: createID)
        guard let menu = button.menu else { return }
        let current = menu.items.map { ($0.representedObject as? String ?? "", $0.attributedTitle ?? NSAttributedString()) }
        if current.count != choices.count || zip(current, choices).contains(where: { $0.0 != $1.id || !$0.1.isEqual($1.title) }) {
            menu.removeAllItems()
            for choice in choices {
                let item = NSMenuItem(title: choice.title.string, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
                item.attributedTitle = choice.title
                item.representedObject = choice.id
                item.target = coordinator
                item.isEnabled = true
                menu.addItem(item)
            }
        }
        let index = choices.firstIndex { $0.id == selection } ?? 0
        button.selectItem(at: index)
        button.invalidateIntrinsicContentSize()
    }

    @MainActor final class Coordinator: NSObject {
        var selection: Binding<String>
        init(selection: Binding<String>) { self.selection = selection }
        @objc func choose(_ item: NSMenuItem) {
            guard let id = item.representedObject as? String else { return }
            selection.wrappedValue = id
        }
    }
}
#endif
