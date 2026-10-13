#if os(macOS)
import AppKit
import SwiftUI

/// Whether the editor panel is open. The window's own commands and shortcuts
/// stand down while it is, as they would for a sheet.
@MainActor @Observable final class EditorPanelPresence {
    static let shared = EditorPanelPresence()
    var isOpen = false
    /// The text field the panel's editor wants focused when the panel opens,
    /// registered by the field itself.
    @ObservationIgnored weak var field: NSView?
}

/// Shows an editor over the window the way a sheet does, without a sheet and
/// without another window.
///
/// - A sheet runs its animations in a nested run loop that holds the main
///   thread for a quarter of a second or more, redrawing the whole window
///   behind it on every frame for the dimming.
/// - A separate window for the editor would take the keyboard by becoming the
///   key window, and every change of key window makes the main window redraw
///   its toolbar, title bar and controls in the inactive look and back, about
///   35ms each way.
///
/// So the editor is drawn in the window, over its content, and the window
/// stays key. The panel dims the content and refuses clicks outside the card;
/// a strip over the title bar and toolbar dims and blocks them; Escape closes;
/// focus moves into the editor and back to where it was.
///
/// Editors that keep their identity across items stay built between uses,
/// hidden, and are built once ahead of the first use from `prewarm`; see
/// `editorSession`.
struct EditorPanel<Item: Identifiable, Editor: View>: View {
    @Binding var item: Item?
    var prewarm: Item?
    @ViewBuilder let editor: (Item) -> Editor
    @State private var lastItem: Item?
    @State private var session = 0
    @State private var prewarmed = false

    var body: some View {
        let visible = item != nil
        let current = item ?? lastItem ?? (prewarmed ? prewarm : nil)
        ZStack {
            if let current {
                EditorPanelBackdrop(visible: visible) {
                    editor(current)
                        .environment(\.closeEditor, close)
                        .environment(\.editorSession, session)
                }
                // Hidden, the panel is transparent and takes no clicks; its
                // views stay in the window so the next use only fills them in.
                .opacity(visible ? 1 : 0)
                .accessibilityHidden(!visible)
            }
        }
        .background(EditorPanelWindowControl(visible: visible, close: close))
        .onChange(of: item.map { AnyHashable($0.id) }) { _, id in
            if id != nil {
                lastItem = item
                // Commands and shortcuts stand down right after the panel's first
                // frame: updating them is menu work the frame need not wait for.
                DispatchQueue.main.async { EditorPanelPresence.shared.isOpen = item != nil }
            } else {
                EditorPanelPresence.shared.isOpen = false
                // A new session while hidden: a kept editor clears itself for the next
                // use, a moment after the close is on screen, so that closing is only
                // hiding.
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { session += 1 }
            }
        }
        .task {
            // After launch has settled: building an editor takes tens of milliseconds.
            try? await Task.sleep(for: .seconds(1))
            prewarmed = true
        }
    }

    private func close() { item = nil }
}

/// The dimmed content and the editor's card, placed where the sheet would be:
/// centered in the window, never above its title bar.
private struct EditorPanelBackdrop<Content: View>: View {
    let visible: Bool
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            // A sheet dims a light window by about a sixth and leaves a dark one
            // nearly as it is. Clicks outside the card are refused, as a sheet's
            // are. The title bar's share is dimmed by EditorPanelWindowControl.
            Color.black.opacity(colorScheme == .dark ? 0.001 : 0.16)
                .contentShape(Rectangle())
                .onTapGesture { NSSound.beep() }
                // Hidden, it must let the page have its clicks. Toggling hit testing
                // costs nothing here: it is a plain colour, no AppKit view to re-attach.
                .allowsHitTesting(visible)
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
            .ignoresSafeArea()
        }
    }
}

/// The panel's dealings with its window: the strip over the title bar and
/// toolbar, Escape, and moving focus in and back out.
private struct EditorPanelWindowControl: NSViewRepresentable {
    let visible: Bool
    let close: @MainActor () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> PassThrough { PassThrough() }
    func updateNSView(_ view: PassThrough, context: Context) {
        let coordinator = context.coordinator
        coordinator.close = close
        guard visible != coordinator.visible, let window = view.window else { return }
        coordinator.visible = visible
        if visible { coordinator.open(over: window, dark: context.environment.colorScheme == .dark) }
        else { coordinator.dismiss() }
    }
    static func dismantleNSView(_ view: PassThrough, coordinator: Coordinator) { coordinator.dismiss() }

    /// Fills the panel's area to reach its window, and never takes a click.
    final class PassThrough: NSView {
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }

    @MainActor final class Coordinator {
        var visible = false
        var close: (@MainActor () -> Void)?
        private weak var window: NSWindow?
        private weak var previousResponder: NSResponder?
        private var strip: TitleBarStrip?
        private var monitor: Any?
        private var observers: [NSObjectProtocol] = []

        func open(over window: NSWindow, dark: Bool) {
            self.window = window
            if let responder = window.firstResponder, responder !== window { previousResponder = responder }
            showStrip(over: window, dark: dark)
            // Focus goes where a sheet would put it, the editor's first text field,
            // right after the panel's first frame: handing focus over from the page
            // takes ~10ms the frame need not wait for, and no one types within a
            // frame of clicking. A field built just now registers once it exists,
            // and focuses itself as it joins the window.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.visible, let window = self.window,
                      let field = EditorPanelPresence.shared.field, field.window === window else { return }
                window.makeFirstResponder(field)
            }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                // Local monitors run on the main thread.
                nonisolated(unsafe) let event = event
                let consumed = MainActor.assumeIsolated { self?.closesOnEscape(event) ?? false }
                return consumed ? nil : event
            }
        }

        func dismiss() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            observers.forEach(NotificationCenter.default.removeObserver)
            observers.removeAll()
            if let strip {
                strip.parent?.removeChildWindow(strip)
                strip.orderOut(nil)
            }
            // Focus goes back where it was, such as the page, if it is still there.
            if let window, let previous = previousResponder as? NSView, previous.window === window {
                window.makeFirstResponder(previous)
            } else if let window, previousResponder == nil {
                window.makeFirstResponder(nil)
            }
            previousResponder = nil
        }

        /// Escape closes the panel wherever focus is in it. A focused text view
        /// would otherwise take the key for itself; text an input method is
        /// still composing keeps it.
        private func closesOnEscape(_ event: NSEvent) -> Bool {
            guard let window, event.window === window, event.keyCode == 53,
                  event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting([.capsLock, .numericPad, .function]).isEmpty,
                  !((window.firstResponder as? NSTextInputClient)?.hasMarkedText() ?? false) else { return false }
            close?()
            return true
        }

        /// The title bar and toolbar are outside the content the panel draws
        /// over; a borderless strip that never takes the keyboard dims them and
        /// refuses their clicks, as a sheet's dimming does.
        private func showStrip(over window: NSWindow, dark: Bool) {
            let strip = self.strip ?? TitleBarStrip()
            self.strip = strip
            strip.backgroundColor = NSColor.black.withAlphaComponent(dark ? 0.001 : 0.16)
            strip.setFrame(Self.titleBarFrame(of: window), display: false)
            if strip.parent !== window { window.addChildWindow(strip, ordered: .above) }
            strip.orderFront(nil)
            let center = NotificationCenter.default
            for name in [NSWindow.didResizeNotification, NSWindow.didEndLiveResizeNotification] {
                observers.append(center.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let window = self.window, let strip = self.strip else { return }
                        strip.setFrame(Self.titleBarFrame(of: window), display: true)
                    }
                })
            }
        }

        private static func titleBarFrame(of window: NSWindow) -> NSRect {
            let frame = window.frame
            let height = max(0, frame.height - window.contentLayoutRect.height)
            return NSRect(x: frame.minX, y: frame.maxY - height, width: frame.width, height: height)
        }
    }
}

/// A transparent strip over the title bar that never becomes key, so the
/// main window keeps the keyboard, and refuses clicks.
private final class TitleBarStrip: NSWindow {
    init() {
        super.init(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: false)
        isOpaque = false
        hasShadow = false
        animationBehavior = .none
        isReleasedWhenClosed = false
        contentView = RefusingView()
        setAccessibilityElement(false)
    }
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    private final class RefusingView: NSView {
        override func mouseDown(with event: NSEvent) { NSSound.beep() }
        override func rightMouseDown(with event: NSEvent) { NSSound.beep() }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    }
}
#endif
