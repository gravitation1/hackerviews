import SwiftUI

struct RootView: View {
    @ObservedObject var store: RecordStore
    @StateObject private var workspace: BrowserWorkspace
    @AppStorage("HackerViews.lastSection") private var section = "read"
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
            TabView(selection: $section) {
                NavigationStack { reading }
                    .tabItem { Label("Read", systemImage: "newspaper") }.tag("read")
                NavigationStack { FiltersView(store: store, openProfile: openProfile) }
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
                    Button("Review in Settings") { section = "settings" }
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
            section = "read"
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
            workspace.saveSession()
            if value != .active { workspace.recordVisits() }
            if value == .active { Task { await store.synchronize() } }
        }
        .onOpenURL { incoming in
            var url = incoming
            if incoming.scheme == "hackerviews", let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
               let value = components.queryItems?.first(where: { $0.name == "url" })?.value, let target = URL(string: value) { url = target }
            if BrowserTab.isHN(url) { workspace.open(url); section = "read" }
        }
    }

    #if os(macOS)
    private var sectionPicker: some View {
        ReaderSectionControl(selection: $section) {
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

    @ViewBuilder private var content: some View {
        switch section {
        case "filters": FiltersView(store: store, openProfile: openProfile)
        case "settings": SettingsView(store: store)
        default: reading
        }
    }

    private func openProfile(_ username: String) {
        var components = URLComponents(string: "https://news.ycombinator.com/user")!
        components.queryItems = [URLQueryItem(name: "id", value: username)]
        guard let url = components.url else { return }
        workspace.open(url)
        section = "read"
    }

    @ViewBuilder private var reading: some View {
        if store.storageAvailable { BrowserView(workspace: workspace) }
        else {
            ContentUnavailableView("Your records need recovery", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text("Browsing is paused so your blocklist is not bypassed. In Settings, restore the recovery copy or import a valid backup. The unreadable file is preserved."))
        }
    }
}

#if os(macOS)
// Target/action also fires when the selected segment is clicked again.
private struct ReaderSectionControl: NSViewRepresentable {
    @Binding var selection: String
    var readAgain: () -> Void
    private static let sections = ["read", "filters", "settings"]

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl(labels: ["Read", "Filters", "Settings"], trackingMode: .selectOne,
                                         target: context.coordinator, action: #selector(Coordinator.select(_:)))
        control.segmentDistribution = .fillEqually
        control.setAccessibilityLabel("Section")
        return control
    }
    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.parent = self
        control.selectedSegment = Self.sections.firstIndex(of: selection) ?? 0
    }
    @MainActor final class Coordinator: NSObject {
        var parent: ReaderSectionControl
        init(_ parent: ReaderSectionControl) { self.parent = parent }
        @objc func select(_ sender: NSSegmentedControl) {
            guard ReaderSectionControl.sections.indices.contains(sender.selectedSegment) else { return }
            let next = ReaderSectionControl.sections[sender.selectedSegment]
            if next == "read" && parent.selection == "read" { parent.readAgain() }
            else { parent.selection = next }
        }
    }
}
#endif
