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
    @ViewBuilder let editor: (Item) -> Editor

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        let coordinator = context.coordinator
        if let item {
            guard coordinator.shownID != AnyHashable(item.id), let window = view.window else { return }
            let binding = $item
            let close: @MainActor () -> Void = { binding.wrappedValue = nil }
            coordinator.show(AnyView(EditorPanelBackdrop { editor(item).environment(\.closeEditor, close) }),
                             id: AnyHashable(item.id), over: window, close: close)
        } else if coordinator.shownID != nil {
            coordinator.hide()
        }
    }

    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.hide() }

    @MainActor final class Coordinator {
        private(set) var shownID: AnyHashable?
        private var panel: EditorPanelWindow?
        private var host: NSHostingView<AnyView>?
        private weak var parent: NSWindow?
        private var observers: [NSObjectProtocol] = []

        func show(_ content: AnyView, id: AnyHashable, over parent: NSWindow, close: @escaping @MainActor () -> Void) {
            if self.parent !== parent { hide(); panel = nil; host = nil }
            let panel = self.panel ?? makePanel()
            let host = self.host ?? NSHostingView(rootView: AnyView(EmptyView()))
            if self.host == nil {
                // The panel's frame is always the parent's, so the hosting view
                // need not measure the editor to size the window.
                host.sizingOptions = []
                panel.contentView = host
                self.host = host
            }
            shownID = id
            self.parent = parent
            panel.onEscape = close
            panel.setFrame(parent.frame, display: false)
            // Ordered in while still empty: ordering a window in looks for its
            // first key view, which in a full editor means SwiftUI building its
            // whole focus and gesture graph inside the call, about 30ms.
            host.rootView = AnyView(EmptyView())
            if panel.parent !== parent { parent.addChildWindow(panel, ordered: .above) }
            panel.orderFront(nil)
            panel.makeKey()
            host.rootView = content
            observe(parent)
            // A sheet starts with its first key view focused, such as the note
            // field. The editor's views exist once its first layout has run.
            DispatchQueue.main.async { [weak panel] in
                guard let panel, panel.isVisible, panel.firstResponder === panel else { return }
                panel.recalculateKeyViewLoop()
                panel.selectNextKeyView(nil)
            }
        }

        func hide() {
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            guard shownID != nil else { return }
            shownID = nil
            panel?.onEscape = nil
            host?.rootView = AnyView(EmptyView())
            if let panel {
                panel.parent?.removeChildWindow(panel)
                panel.orderOut(nil)
            }
            parent?.makeKey()
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
