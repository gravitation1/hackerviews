import AppKit
import SwiftUI

@main struct EffectMenuSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        var rule = FilterRule()
        let coordinator = MacFilterEffectPicker.Coordinator(rule: Binding(get: { rule }, set: { rule = $0 }))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let sheet = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 500, height: 300), styleMask: [.titled], backing: .buffered, defer: false)
        let normalButton = MacFilterEffectPicker.makeButton(coordinator: coordinator)
        let sheetButton = MacFilterEffectPicker.makeButton(coordinator: coordinator)
        window.contentView = normalButton
        sheet.contentView = sheetButton
        window.beginSheet(sheet)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(250))
            precondition(sheet.sheetParent === window)
            for (name, button) in [("window", normalButton), ("sheet", sheetButton)] {
                let menu = button.menu!
                precondition(!menu.autoenablesItems)
                menu.update()
                precondition(menu.items.dropFirst().allSatisfy(\.isEnabled))
                precondition(menu.items.map(\.title) == ["Effect"] + MacFilterEffectPicker.choices.map(\.title))
                for item in menu.items.dropFirst() {
                    precondition(app.sendAction(item.action!, to: item.target, from: item))
                    let expected = MacFilterEffectPicker.choices[item.tag]
                    precondition(rule.effect == expected.effect)
                    if let fade = expected.fade { precondition(rule.fade == fade) }
                    if let color = expected.color { precondition(rule.color == color) }
                    MacFilterEffectPicker.refresh(button, rule: rule)
                    precondition(button.selectedItem?.title == item.title)
                }
                print("PASS \(name): all 11 effects enabled, actionable, and selected correctly")
            }
            window.endSheet(sheet)
            exit(0)
        }
        app.run()
    }
}
