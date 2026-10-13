import SwiftUI

struct RootView: View {
    @ObservedObject var store: RecordStore
    @StateObject private var workspace: BrowserWorkspace
    // Held, not observed: a switch re-renders the views that show the section,
    // never this one.
    @State private var sections = SectionSelection()
    @State private var filterQuery = ""
    @Environment(\.scenePhase) private var phase

    init(store: RecordStore) {
        self.store = store
        _workspace = StateObject(wrappedValue: BrowserWorkspace(store: store))
    }

    var body: some View {
        Group {
            #if os(macOS)
            NavigationStack {
                content
                    .navigationTitle("")
                    .toolbar {
                        sectionToolbar
                    }
            }
            #else
            TabView(selection: Bindable(sections).current) {
                NavigationStack { ReaderSection(workspace: workspace, available: store.storageAvailable) }
                    .tabItem { Label("Read", systemImage: "newspaper") }.tag("read")
                NavigationStack { FiltersView(store: store, query: $filterQuery, openProfile: openProfile) }
                    .tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease") }.tag("filters")
                NavigationStack { SettingsView(store: store) }
                    .tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
            }
            #endif
        }
        .safeAreaInset(edge: .bottom) {
            if store.recoveryNotice != nil {
                HStack {
                    Text("Recovery was incomplete. Some edits may be missing.")
                    Button("Review in Settings") { sections.current = "settings" }
                }.font(.caption).padding(8)
            }
        }
        .sheet(item: $workspace.draft) { draft in
            RecordEditor(store: store, draft: draft)
        }
        .environment(\.openURL, OpenURLAction { url in
            guard BrowserTab.isHN(url) else {
                #if os(macOS)
                ExternalBrowser.open(url)
                return .handled
                #else
                return .systemAction
                #endif
            }
            NotificationCenter.default.post(name: Notification.Name("HackerViewsOpenReference"), object: nil)
            workspace.draft = nil
            workspace.open(url)
            sections.current = "read"
            return .handled
        })
        .alert("Couldn’t save your records", isPresented: Binding(get: { store.error != nil }, set: { if !$0 { store.error = nil } })) {
            Button("OK") { store.error = nil }
        } message: { Text(store.error ?? "") }
        .task {
            workspace.start()
            await store.synchronize()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                if phase == .active { await store.synchronize() }
            }
        }
        .onChange(of: phase) { _, value in
            sections.save()
            workspace.saveSession()
            if value != .active { workspace.recordVisits() }
            if value == .active { Task { await store.synchronize() } }
        }
        #if os(macOS)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in sections.save() }
        #endif
        .onOpenURL { incoming in
            var url = incoming
            if incoming.scheme == "hackerviews", let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
               let value = components.queryItems?.first(where: { $0.name == "url" })?.value, let target = URL(string: value) { url = target }
            if BrowserTab.isHN(url) { workspace.open(url); sections.current = "read" }
        }
    }

    #if os(macOS)
    private var sectionPicker: some View {
        SectionPicker(selection: sections) {
            workspace.selected?.scrollToTop()
        }
        .frame(width: 250)
    }

    @ToolbarContentBuilder private var sectionToolbar: some ToolbarContent {
        if #available(macOS 26.0, *) {
            // The segmented control owns its background. A second toolbar capsule
            // has different vertical metrics and makes the selection look offset.
            ToolbarItem(placement: .principal) { sectionPicker }
                .sharedBackgroundVisibility(.hidden)
        } else {
            ToolbarItem(placement: .principal) { sectionPicker }
        }
    }
    #endif

    #if os(macOS)
    private var content: some View {
        SectionStack(selection: sections, store: store, workspace: workspace, readerAvailable: store.storageAvailable,
                     filterQuery: $filterQuery, openProfile: openProfile, onSwitch: moveKeyFocus)
    }

    /// Keys typed in one section must not reach a hidden one: the reader's page
    /// takes focus when it shows, and any other switch clears it.
    private func moveKeyFocus(to section: String) {
        let webView = workspace.selected?.displayedPage.webView
        guard let window = webView?.window ?? NSApp.keyWindow else { return }
        if section == "read", let webView, webView.window === window { window.makeFirstResponder(webView) }
        else { window.makeFirstResponder(nil) }
    }
    #endif

    private func openProfile(_ username: String) {
        var components = URLComponents(string: "https://news.ycombinator.com/user")!
        components.queryItems = [URLQueryItem(name: "id", value: username)]
        guard let url = components.url else { return }
        workspace.open(url)
        sections.current = "read"
    }
}

#if os(macOS)
/// The section control, the only part of the toolbar that follows the section.
private struct SectionPicker: View {
    let selection: SectionSelection
    var readAgain: () -> Void
    var body: some View {
        ReaderSectionControl(selection: selection.current, select: { selection.current = $0 }, readAgain: readAgain)
    }
}

// Target/action also fires when the selected segment is clicked again.
private struct ReaderSectionControl: NSViewRepresentable {
    var selection: String
    var select: (String) -> Void
    var readAgain: () -> Void
    private static let sections = SectionSelection.sections

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = PressSegmentedControl(labels: ["Read", "Filters", "Settings"], trackingMode: .selectOne,
                                            target: context.coordinator, action: #selector(Coordinator.select(_:)))
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("Section")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = Self.sections.firstIndex(of: selection) ?? 0
    }
    /// Switches on mouse-down, as browser tab strips do. A segmented control
    /// sends its action on mouse-up, which keeps every switch waiting for the
    /// button's release, about a tenth of a second.
    final class PressSegmentedControl: NSSegmentedControl {
        override func mouseDown(with event: NSEvent) {
            guard segmentCount > 0, bounds.width > 0 else { return super.mouseDown(with: event) }
            let point = convert(event.locationInWindow, from: nil)
            let index = min(segmentCount - 1, max(0, Int(point.x / (bounds.width / CGFloat(segmentCount)))))
            guard isEnabled(forSegment: index) else { return }
            selectedSegment = index
            sendAction(action, to: target)
        }
    }
    @MainActor final class Coordinator: NSObject {
        var parent: ReaderSectionControl
        init(_ parent: ReaderSectionControl) { self.parent = parent }
        @objc func select(_ sender: NSSegmentedControl) {
            guard ReaderSectionControl.sections.indices.contains(sender.selectedSegment) else { return }
            let next = ReaderSectionControl.sections[sender.selectedSegment]
            if next == "read" && parent.selection == "read" { parent.readAgain() }
            else {
                #if DEBUG
                SectionSwitchTiming.begin(from: parent.selection, to: next, event: NSApp.currentEvent, view: sender.window?.contentView)
                #endif
                parent.select(next)
            }
        }
    }
}
#endif
