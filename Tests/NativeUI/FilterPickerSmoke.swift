import AppKit
import SwiftUI

/// The filter pop-up of the flag sheet: every choice enabled and actionable in
/// a sheet, a highlight filter's name in its colour and nothing else coloured,
/// the selection shown on the button's face. With a directory argument it also
/// renders the sheet's section and the Filters table in both appearances.
@main struct FilterPickerSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        func rule(_ name: String, _ effect: FilterRule.Effect, color: FilterRule.Accent = .teal, enabled: Bool = true) -> FilterRule {
            var rule = FilterRule(); rule.name = name; rule.effect = effect; rule.color = color; rule.enabled = enabled; rule.members = []; return rule
        }
        var rules = [rule("Shill", .block), rule("Anthropic Employee", .highlight, color: .pink), rule("Fresh Air", .highlight, color: .green, enabled: false),
                     rule("Confident Idiot", .fade), rule("Thoughtful", .highlight, color: .blue)]
        let createID = "create-new-filter"
        var selection = ""
        let coordinator = MacFilterPicker.Coordinator(selection: Binding(get: { selection }, set: { selection = $0 }))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let normalButton = MacFilterPicker.makeButton(coordinator: coordinator)
        let sheetButton = MacFilterPicker.makeButton(coordinator: coordinator)
        func refresh(_ button: NSPopUpButton) { MacFilterPicker.refresh(button, coordinator: coordinator, rules: rules, createID: createID, selection: selection) }
        refresh(normalButton); refresh(sheetButton)
        window.contentView = normalButton
        sheet.contentView = sheetButton
        window.beginSheet(sheet)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            precondition(sheet.sheetParent === window)
            func colour(_ title: NSAttributedString, at location: Int) -> NSColor? { title.attribute(.foregroundColor, at: location, effectiveRange: nil) as? NSColor }
            let choices = MacFilterPicker.choices(rules: rules, createID: createID)
            precondition(choices.map(\.id) == ["", createID] + rules.map(\.id))
            precondition(choices.map(\.title.string) == ["No filter · Note only", "Create filter…", "Shill · Block", "Anthropic Employee · Highlight · Pink",
                                                         "Fresh Air · Highlight · Green · Paused", "Confident Idiot · Fade · Medium (50%)", "Thoughtful · Highlight · Blue"])
            precondition(colour(choices[2].title, at: 0) == nil, "a block filter's name carries no colour")
            precondition(colour(choices[3].title, at: 0) == FilterRule.Accent.pink.nsColor, "a highlight filter's name is in its colour")
            precondition(colour(choices[3].title, at: choices[3].title.length - 1) == nil, "the effect after the name is not")
            let paused = colour(choices[4].title, at: 0)!
            precondition(abs(paused.alphaComponent - 0.5) < 0.01 && paused.withAlphaComponent(1) == FilterRule.Accent.green.nsColor, "paused, the colour fades")
            for (name, button) in [("window", normalButton), ("sheet", sheetButton)] {
                let menu = button.menu!
                precondition(!menu.autoenablesItems)
                menu.update()
                precondition(menu.items.allSatisfy(\.isEnabled))
                precondition(menu.items.map(\.title) == choices.map(\.title.string))
                precondition(menu.items.map { $0.representedObject as? String } == choices.map { $0.id })
                for (index, item) in menu.items.enumerated() {
                    precondition(app.sendAction(item.action!, to: item.target, from: item))
                    precondition(selection == choices[index].id)
                    refresh(button)
                    precondition(button.indexOfSelectedItem == index)
                    precondition(button.attributedTitle.string == choices[index].title.string)
                    precondition(button.attributedTitle.isEqual(choices[index].title), "the face shows the item's title, colour and all")
                }
                let before = menu.items
                refresh(button)
                precondition(menu.items.elementsEqual(before, by: ===), "unchanged filters keep their items")
                rules[0].name = "Shills"; refresh(button)
                precondition(menu.items[2].title == "Shills · Block", "a renamed filter rebuilds the items")
                rules[0].name = "Shill"; refresh(button)
                print("PASS \(name): all \(choices.count) choices enabled, actionable and shown; highlight names in their colour")
            }
            window.endSheet(sheet)
            if CommandLine.arguments.count > 1 { await render(rules, createID: createID, to: CommandLine.arguments[1]) }
            exit(0)
        }
        app.run()
    }

    struct FlagSample: View {
        @ObservedObject var store: RecordStore
        var createID: String
        @State var filterID: String
        @State var userTarget = true
        var body: some View {
            Form {
                Section {
                    Picker("Apply to", selection: $userTarget) { Text("This user").tag(true); Text("Only this contribution").tag(false) }.pickerStyle(.segmented)
                    LabeledContent("Add mkobit to filter") {
                        MacFilterPicker(selection: $filterID, rules: store.archive.rules, createID: createID, accessibilityLabel: "Add mkobit to filter").fixedSize()
                    }
                    if let selected = store.archive.rules.first(where: { $0.id == filterID }) {
                        (Text("Adds mkobit to ") + selected.nameText + Text(". The filter’s scope and other conditions still apply."))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } header: { Text("Flag mkobit") }
            }.formStyle(.grouped)
        }
    }
    @MainActor static func render(_ rules: [FilterRule], createID: String, to directory: String) async {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RecordStore(directory: dir)
        _ = store.saveRules(rules)
        for (appearance, suffix) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
            await snapshot(NSHostingView(rootView: FlagSample(store: store, createID: createID, filterID: rules[1].id)), size: NSSize(width: 640, height: 200), appearance: appearance, to: directory + "/flag-" + suffix + ".png")
            await snapshot(NSHostingView(rootView: FiltersView(store: store, openProfile: { _ in })), size: NSSize(width: 1100, height: 420), appearance: appearance, to: directory + "/filters-" + suffix + ".png")
        }
        try? FileManager.default.removeItem(at: dir)
    }
    @MainActor static func snapshot(_ view: NSView, size: NSSize, appearance: NSAppearance.Name, to path: String) async {
        let window = NSWindow(contentRect: NSRect(origin: NSPoint(x: -10000, y: -10000), size: size), styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        view.frame = NSRect(origin: .zero, size: size)
        window.contentView = view
        window.orderBack(nil)
        try? await Task.sleep(for: .milliseconds(500))
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { print("no snapshot", path); return }
        view.cacheDisplay(in: view.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: path))
        window.orderOut(nil)
    }
}
