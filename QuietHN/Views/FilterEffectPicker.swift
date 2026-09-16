import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The complete effect menu shared by the table and filter editor.
struct FilterEffectPicker: View {
    @Binding var rule: FilterRule

    private var selection: Binding<String> {
        Binding(get: {
            switch rule.effect {
            case .highlight: "highlight:" + rule.color.rawValue
            case .fade: "fade:" + String(rule.fade.rawValue)
            default: rule.effect.rawValue
            }
        }, set: { choice in
            var updated = rule
            if choice.hasPrefix("highlight:"), let color = FilterRule.Accent(rawValue: String(choice.dropFirst(10))) {
                updated.effect = .highlight; updated.color = color
            } else if choice.hasPrefix("fade:"), let value = Int(choice.dropFirst(5)), let level = FilterRule.FadeLevel(rawValue: value) {
                updated.effect = .fade; updated.fadeLevel = level
            } else if let effect = FilterRule.Effect(rawValue: choice) {
                updated.effect = effect
            } else { return }
            rule = updated
        })
    }

    private var options: some View {
        Picker("Effect", selection: selection) {
            Label("Block", systemImage: "hand.raised.fill").tag("block")
            ForEach(FilterRule.FadeLevel.allCases, id: \.self) { level in
                Label("Fade · " + level.label, systemImage: "circle.lefthalf.filled")
                    .tag("fade:" + String(level.rawValue))
            }
            Label("Show normally", systemImage: "eye").tag("allow")
            ForEach(FilterRule.Accent.allCases, id: \.self) { color in
                Label { Text("Highlight · " + color.rawValue.capitalized) } icon: { color.swatch }
                    .tag("highlight:" + color.rawValue)
            }
        }
    }

    var body: some View {
        #if os(macOS)
        MacFilterEffectPicker(rule: $rule).fixedSize()
        #else
        Menu {
            options.pickerStyle(.inline)
        } label: {
            HStack(spacing: 6) {
                if rule.effect == .highlight { rule.color.swatch }
                else { Image(systemName: rule.effect == .block ? "hand.raised.fill" : (rule.effect == .fade ? "circle.lefthalf.filled" : "eye")) }
                Text(rule.effectLabel)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
            }
            .font(.caption)
            .foregroundStyle(rule.effect == .highlight ? rule.color.swiftUI : (rule.effect == .block ? Color.orange : Color.secondary))
            .padding(.horizontal, 8).padding(.vertical, 5)
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .tint(.gray)
        .accentColor(.gray)
        .fixedSize()
        .help("Change effect")
        .accessibilityLabel("Change effect for \(rule.name.isEmpty ? rule.summary : rule.name)")
        #endif
    }

}

#if os(macOS)
/// Own the native menu and its actions so sheet responder validation cannot disable choices.
struct MacFilterEffectPicker: NSViewRepresentable {
    @Binding var rule: FilterRule

    struct Choice {
        var title: String
        var effect: FilterRule.Effect
        var fade: FilterRule.FadeLevel?
        var color: FilterRule.Accent?
        var symbol: String
    }
    static var choices: [Choice] {
        [Choice(title: "Block", effect: .block, symbol: "hand.raised.fill")] +
        FilterRule.FadeLevel.allCases.map { Choice(title: "Fade · " + $0.label, effect: .fade, fade: $0, symbol: "circle.lefthalf.filled") } +
        [Choice(title: "Show normally", effect: .allow, symbol: "eye")] +
        FilterRule.Accent.allCases.map { Choice(title: "Highlight · " + $0.rawValue.capitalized, effect: .highlight, color: $0, symbol: "circle.fill") }
    }

    func makeCoordinator() -> Coordinator { Coordinator(rule: $rule) }
    func makeNSView(context: Context) -> NSPopUpButton { Self.makeButton(coordinator: context.coordinator) }

    static func makeButton(coordinator: Coordinator) -> NSPopUpButton {
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        button.bezelStyle = .rounded
        let menu = NSMenu(title: "Effect")
        menu.autoenablesItems = false
        let heading = NSMenuItem(title: "Effect", action: nil, keyEquivalent: "")
        heading.isEnabled = false; menu.addItem(heading)
        for (index, choice) in choices.enumerated() {
            let item = NSMenuItem(title: choice.title, action: #selector(Coordinator.choose(_:)), keyEquivalent: "")
            item.target = coordinator; item.tag = index; item.isEnabled = true
            if let color = choice.color {
                let value = UInt32(color.hex.dropFirst(), radix: 16) ?? 0
                let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
                    NSColor(srgbRed: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255, alpha: 1).setFill()
                    NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12)).fill()
                    return true
                }
                image.isTemplate = false; item.image = image
            } else {
                item.image = NSImage(systemSymbolName: choice.symbol, accessibilityDescription: nil)
            }
            menu.addItem(item)
        }
        button.menu = menu
        return button
    }

    func updateNSView(_ button: NSPopUpButton, context: Context) {
        context.coordinator.rule = $rule
        Self.refresh(button, rule: rule)
    }

    static func refresh(_ button: NSPopUpButton, rule: FilterRule) {
        let index = choices.firstIndex {
            $0.effect == rule.effect && ($0.fade == nil || $0.fade == rule.fade) && ($0.color == nil || $0.color == rule.color)
        } ?? 0
        button.selectItem(at: index + 1)
        button.setAccessibilityLabel("Change effect for " + (rule.name.isEmpty ? "filter" : rule.name))
    }

    @MainActor final class Coordinator: NSObject {
        var rule: Binding<FilterRule>
        init(rule: Binding<FilterRule>) { self.rule = rule }
        @objc func choose(_ item: NSMenuItem) {
            guard MacFilterEffectPicker.choices.indices.contains(item.tag) else { return }
            let choice = MacFilterEffectPicker.choices[item.tag]
            var value = rule.wrappedValue
            value.effect = choice.effect
            if let level = choice.fade { value.fadeLevel = level }
            if let color = choice.color { value.color = color }
            rule.wrappedValue = value
        }
    }
}
#endif
