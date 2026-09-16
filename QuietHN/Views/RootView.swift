import SwiftUI

struct RootView: View {
    @ObservedObject var store: RecordStore
    @StateObject private var workspace: BrowserWorkspace
    @State private var section = "read"
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
                    .toolbar {
                        ToolbarItem(placement: .principal) {
                            Picker("Section", selection: $section) {
                                Text("Read").tag("read")
                                Text("Filters").tag("filters")
                                Text("Settings").tag("settings")
                            }
                            .pickerStyle(.segmented)
                            .frame(width: 250)
                        }
                    }
            }
            #else
            TabView(selection: $section) {
                NavigationStack { reading }
                    .tabItem { Label("Read", systemImage: "newspaper") }.tag("read")
                NavigationStack { FiltersView(store: store) }
                    .tabItem { Label("Filters", systemImage: "line.3.horizontal.decrease") }.tag("filters")
                NavigationStack { SettingsView(store: store) }
                    .tabItem { Label("Settings", systemImage: "gearshape") }.tag("settings")
            }
            #endif
        }
        .sheet(item: $workspace.draft) { draft in
            RecordEditor(store: store, draft: draft)
        }
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
        .onChange(of: phase) { _, value in if value == .active { Task { await store.synchronize() } } }
        .onOpenURL { incoming in
            var url = incoming
            if incoming.scheme == "quiethn", let components = URLComponents(url: incoming, resolvingAgainstBaseURL: false),
               let value = components.queryItems?.first(where: { $0.name == "url" })?.value, let target = URL(string: value) { url = target }
            if BrowserTab.isHN(url) { workspace.open(url); section = "read" }
        }
    }

    @ViewBuilder private var content: some View {
        switch section {
        case "filters": FiltersView(store: store)
        case "settings": SettingsView(store: store)
        default: reading
        }
    }

    @ViewBuilder private var reading: some View {
        if store.storageAvailable { BrowserView(workspace: workspace) }
        else {
            ContentUnavailableView("Your records need recovery", systemImage: "externaldrive.badge.exclamationmark",
                                   description: Text("Browsing is paused so your blocklist is not bypassed. In Settings, restore the recovery copy or import a valid backup. The unreadable file is preserved."))
        }
    }
}
