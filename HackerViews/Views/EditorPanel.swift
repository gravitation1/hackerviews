#if os(macOS)
import AppKit
import SwiftUI

/// Shows an editor over its window the way a sheet does, without a sheet.
/// AppKit runs a sheet's opening and closing animations in a nested run loop
/// that holds the main thread for a quarter of a second or more, and redraws
/// the whole window behind it for the dimming on every frame of them. The
/// panel is a borderless child window over the parent's full frame: it dims
/// the window, title bar and toolbar included, takes the clicks and the keys,
/// and appears in the next frame.
struct EditorPanelHost<Item: Identifiable, Editor: View>: NSViewRepresentable {
    @Binding var item: Item?
    /// Built into the panel shortly after launch, so that the first use opens
    /// as fast as later ones. Editors that keep their identity across items
    /// stay built from then on; see `editorSession`.
    var prewarm: Item?
    @ViewBuilder let editor: (Item) -> Editor

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> Anchor {
        let anchor = Anchor()
        let coordinator = context.coordinator
        // The prewarm needs the window, which this view joins after its first update.
        anchor.onWindow = { [weak coordinator] window in coordinator?.schedulePrewarm(over: window) }
        return anchor
    }

    final class Anchor: NSView {
        var onWindow: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { onWindow?(window) }
        }
    }

    func updateNSView(_ view: Anchor, context: Context) {
        let coordinator = context.coordinator
        let binding = $item
        let close: @MainActor () -> Void = { binding.wrappedValue = nil }
        coordinator.make = { item, session in
            AnyView(EditorPanelBackdrop {
                editor(item).environment(\.closeEditor, close).environment(\.editorSession, session)
            })
        }
        coordinator.close = close
        coordinator.prewarm = prewarm
        if let item {
            guard coordinator.shownID != AnyHashable(item.id), let window = view.window else { return }
            coordinator.show(item, over: window)
        } else if coordinator.shownID != nil {
            coordinator.hide()
        }
        if let window = view.window { coordinator.schedulePrewarm(over: window) }
    }

    static func dismantleNSView(_ view: Anchor, coordinator: Coordinator) { coordinator.hide() }

    @MainActor final class Coordinator {
        private(set) var shownID: AnyHashable?
        private var prewarmScheduled = false
        var prewarm: Item?
        var make: ((Item, Int) -> AnyView)?
        var close: (@MainActor () -> Void)?
        private var lastItem: Item?
        private var session = 0
        private var panel: EditorPanelWindow?
        private var host: NSHostingView<AnyView>?
        private weak var parent: NSWindow?
        private var observers: [NSObjectProtocol] = []

        /// Builds the prewarm editor in the panel without showing it, once,
        /// after launch has settled: building an editor takes tens of milliseconds.
        func schedulePrewarm(over parent: NSWindow) {
            guard !prewarmScheduled, prewarm != nil else { return }
            prewarmScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak parent] in
                MainActor.assumeIsolated {
                    guard let self, let parent, let prewarm = self.prewarm, self.shownID == nil, self.lastItem == nil else { return }
                    self.fill(prewarm, over: parent)
                }
            }
        }

        /// Puts the editor for `item` in the panel and lays it out, reusing the
        /// views already there where the editor keeps its identity.
        private func fill(_ item: Item, over parent: NSWindow) {
            guard let make else { return }
            if self.parent !== parent, self.parent != nil { hide(); panel = nil; host = nil; lastItem = nil }
            let panel = self.panel ?? makePanel()
            let host = self.host ?? {
                let host = NSHostingView(rootView: make(item, session))
                // The panel's frame is always the parent's, so the hosting view
                // need not measure the editor to size the window.
                host.sizingOptions = []
                panel.contentView = host
                self.host = host
                return host
            }()
            self.parent = parent
            lastItem = item
            host.rootView = make(item, session)
            panel.setFrame(parent.frame, display: false)
            host.layoutSubtreeIfNeeded()
        }

        func show(_ item: Item, over parent: NSWindow) {
            fill(item, over: parent)
            guard let panel, let host else { return }
            shownID = AnyHashable(item.id)
            panel.onEscape = close
            // Focus goes where a sheet would put it, the first text field, and
            // goes there before the window is ordered in: a window ordered in with
            // nothing focused searches for its first key view, which makes
            // SwiftUI build the editor's whole focus and gesture graph, ~30ms.
            // An editor built just now has no text view yet; its note field
            // focuses itself when it joins the window.
            if let field = Self.firstTextView(in: host) { panel.makeFirstResponder(field) }
            if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
            panel.makeKey()
            observe(parent)

        }

        func hide() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard shownID != nil else { return }
            shownID = nil
            panel?.onEscape = nil
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            // A new session while hidden: a kept editor clears itself for the next use.
            session += 1
            if let lastItem, let make { host?.rootView = make(lastItem, session) }
            parent?.makeKey()
        }

        private static func firstTextView(in view: NSView) -> NSTextView? {
            if let text = view as? NSTextView, text.isEditable { return text }
            for child in view.subviews { if let found = firstTextView(in: child) { return found } }
            return nil
        }

        private func makePanel() -> EditorPanelWindow {
            let panel = EditorPanelWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.isOpaque = false
            panel.backgroundColor = .clear
            panel.hasShadow = false
            panel.animationBehavior = .none
            panel.isReleasedWhenClosed = false
            panel.setAccessibilitySubrole(.dialog)
            self.panel = panel
            return panel
        }

        /// The panel covers the parent exactly, so it follows the parent's
        /// size. Child windows already move with their parent.
        private func observe(_ parent: NSWindow) {
            guard observers.isEmpty else { return }
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                observers.append(center.addObserver(forName: name, object: parent, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let panel = self.panel, let parent = self.parent else { return }
                        panel.setFrame(parent.frame, display: true)
                    }
                })
            }
        }
    }
}

/// Borderless windows cannot become key by default; the panel must, to take
/// the keyboard as a sheet does.
final class EditorPanelWindow: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
    /// Escape closes the panel wherever the focus is. A focused text view
    /// would otherwise take the key for itself, so no button's shortcut sees
    /// it; text an input method is still composing keeps it.
    var onEscape: (@MainActor () -> Void)?
    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty,
           !((firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false),
           let onEscape {
            onEscape()
            return
        }
        super.sendEvent(event)
    }
}

/// The dimmed window and the editor's card, placed where the sheet would be:
/// centered in the window, never above its title bar.
private struct EditorPanelBackdrop<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // A sheet dims a light window by about a sixth and leaves a dark one
            // nearly as it is. Clicks outside the card are refused, as a sheet's are.
            Color.black.opacity(colorScheme == .dark ? 0.001 : 0.16)
                .contentShape(Rectangle())
                .onTapGesture { NSSound.beep() }
                .accessibilityHidden(true)
            VStack(spacing: 0) {
                Spacer(minLength: 32)
                content
                    .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.separator, lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.3), radius: 24, y: 8)
                    .accessibilityAddTraits(.isModal)
                Spacer(minLength: 8)
            }
        }
        .ignoresSafeArea()
    }
}
#endif
