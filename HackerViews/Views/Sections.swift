import SwiftUI
#if os(macOS)
import AppKit
#endif

/// The section on screen, remembered across launches. Views that depend on it
/// read it through `@SectionShown`, so a switch re-renders only those small
/// views and never the sections themselves.
@MainActor @Observable final class SectionSelection {
    static let sections = ["read", "filters", "settings"]
    private static let key = "HackerViews.lastSection"
    var current: String
    init() {
        let saved = UserDefaults.standard.string(forKey: Self.key) ?? "read"
        current = Self.sections.contains(saved) ? saved : "read"
    }
    /// Called when the app goes inactive or quits, not on each switch: any
    /// UserDefaults write re-renders every view that uses `@AppStorage`.
    func save() { UserDefaults.standard.set(current, forKey: Self.key) }
}

private struct SectionNameKey: EnvironmentKey { static let defaultValue: String? = nil }
extension EnvironmentValues {
    /// The section a view belongs to. Set once per section and never changed.
    var sectionName: String? {
        get { self[SectionNameKey.self] }
        set { self[SectionNameKey.self] = newValue }
    }
}

/// Whether the enclosing section is the one on screen; true where sections
/// are not stacked, as on iPhone. A view reading it re-renders on a switch.
@propertyWrapper struct SectionShown: DynamicProperty {
    @Environment(SectionSelection.self) private var selection: SectionSelection?
    @Environment(\.sectionName) private var name
    @MainActor var wrappedValue: Bool {
        guard let selection, let name else { return true }
        return selection.current == name
    }
}

/// A keyboard shortcut that only works while its section is on screen.
struct SectionShortcut: ViewModifier {
    let shortcut: KeyboardShortcut
    @SectionShown private var shown
    func body(content: Content) -> some View { content.keyboardShortcut(shown ? shortcut : nil) }
}

/// Runs `action` when the enclosing section is shown (true) or hidden (false).
struct SectionVisibilityChange: ViewModifier {
    let action: (Bool) -> Void
    @SectionShown private var shown
    func body(content: Content) -> some View { content.onChange(of: shown) { _, value in action(value) } }
}

/// The reader, or why it is paused. Equal while it shows the same thing.
struct ReaderSection: View, @preconcurrency Equatable {
    let workspace: BrowserWorkspace
    let available: Bool
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.workspace === rhs.workspace && lhs.available == rhs.available }
    var body: some View {
        if available { BrowserView(workspace: workspace) }
        else {
            ContentUnavailableView("Your records need recovery", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text("Browsing is paused so your blocklist is not bypassed. In Settings, restore the recovery copy or import a valid backup. The unreadable file is preserved."))
        }
    }
}

#if os(macOS)
/// The Mac's sections, all mounted at once so that switching only changes
/// which one shows: building a section takes tens of milliseconds, showing
/// one that exists takes a frame.
///
/// - Each section is wrapped so that it compares equal across renders of this
///   stack, and so is not re-rendered by a switch.
/// - A hidden section has opacity 0 under the shown one, which keeps clicks
///   off it. Toggling `allowsHitTesting` instead would detach and re-attach its
///   AppKit views (the web view, the filter table) on every switch.
/// - Filters' search field is the window toolbar's. A hidden view's
///   `.searchable` still puts it there, and adding it on each switch builds a
///   new toolbar item, so on macOS 15 and later it stays and is hidden in
///   AppKit outside Filters.
struct SectionStack: View {
    let selection: SectionSelection
    let store: RecordStore
    let workspace: BrowserWorkspace
    let readerAvailable: Bool
    @Binding var filterQuery: String
    let openProfile: (String) -> Void
    let onSwitch: (String) -> Void

    var body: some View {
        let section = selection.current
        let stack = ZStack {
            layer("read", section, ReaderSection(workspace: workspace, available: readerAvailable))
            layer("filters", section, FiltersSection(store: store, query: $filterQuery, openProfile: openProfile))
            layer("settings", section, SettingsSection(store: store))
        }
        Group {
            if #available(macOS 15.0, *) {
                stack.searchable(text: $filterQuery, prompt: FiltersView.searchPrompt)
                    .background(SearchItemVisibility(shown: section == "filters"))
            } else {
                stack.overlay {
                    if section == "filters" {
                        Color.clear.frame(width: 0, height: 0).searchable(text: $filterQuery, prompt: FiltersView.searchPrompt)
                    }
                }
            }
        }
        .environment(selection)
        .onChange(of: section) { _, value in onSwitch(value) }
    }

    private func layer(_ name: String, _ section: String, _ content: some View) -> some View {
        let shown = section == name
        return content
            .environment(\.sectionName, name)
            .opacity(shown ? 1 : 0)
            .zIndex(shown ? 1 : 0)
            .accessibilityHidden(!shown)
    }
}

/// Equal for the same store: the query binding and the profile action always
/// lead to the same root view's state, so they need not be compared.
private struct FiltersSection: View, @preconcurrency Equatable {
    let store: RecordStore
    @Binding var query: String
    let openProfile: (String) -> Void
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.store === rhs.store }
    var body: some View { FiltersView(store: store, query: $query, openProfile: openProfile) }
}

private struct SettingsSection: View, @preconcurrency Equatable {
    let store: RecordStore
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.store === rhs.store }
    var body: some View { SettingsView(store: store) }
}

/// Hides the window's search toolbar item while Filters is not on screen.
/// The item stays in the toolbar, so showing it again is a layout change, not
/// a new item. A toolbar that gains a search item again gets the same state.
@available(macOS 15.0, *)
private struct SearchItemVisibility: NSViewRepresentable {
    let shown: Bool
    final class Marker: NSView {
        var shown = false { didSet { apply() } }
        private var observer: NSObjectProtocol?
        override func viewWillMove(toWindow newWindow: NSWindow?) {
            super.viewWillMove(toWindow: newWindow)
            if let observer { NotificationCenter.default.removeObserver(observer); self.observer = nil }
        }
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard window != nil else { return }
            // Any toolbar: SwiftUI may build this window's toolbar, and its
            // search item, after this view is already in the window.
            observer = NotificationCenter.default.addObserver(forName: NSToolbar.willAddItemNotification, object: nil, queue: .main) { [weak self] note in
                let toolbar = note.object as? NSToolbar
                // The item is in the toolbar once this notification's turn ends.
                Task { @MainActor in if let self, toolbar === self.window?.toolbar { self.apply() } }
            }
            apply()
        }
        func apply() {
            for item in window?.toolbar?.items ?? [] where item is NSSearchToolbarItem && item.isHidden == shown { item.isHidden = !shown }
        }
    }
    func makeNSView(context: Context) -> Marker { Marker() }
    func updateNSView(_ marker: Marker, context: Context) { marker.shown = shown }
}

/// Reports a fixed minimum size without measuring its content. Under a
/// minimum-size frame, AppKit's window size limits would measure the whole
/// view tree, every stacked section included, on each update.
struct MinimumSize: Layout {
    let width: CGFloat
    let height: CGFloat
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        CGSize(width: max(width, proposal.width ?? width), height: max(height, proposal.height ?? height))
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for subview in subviews { subview.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size)) }
    }
}
#endif
