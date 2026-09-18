import SwiftUI
import WebKit

struct BrowserView: View {
    @ObservedObject var workspace: BrowserWorkspace
    @State private var showOpen = false
    @State private var address = ""
    @State private var linkError = false

    var body: some View {
        VStack(spacing: 0) {
            if workspace.tabs.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(workspace.tabs) { tab in
                            TabChip(tab: tab, selected: workspace.selectedID == tab.id,
                                    select: { workspace.selectedID = tab.id }, close: { workspace.close(tab) })
                        }
                    }.padding(8)
                }
                Divider()
            }
            if let tab = workspace.selected { BrowserPage(tab: tab).id(tab.id) }
        }
        #if os(iOS)
        .navigationTitle("HackerViews")
        #else
        .navigationTitle("")
        .focusedSceneObject(workspace)
        #endif
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            #if os(macOS)
            ToolbarItem(placement: .primaryAction) {
                if let tab = workspace.selected {
                    ReaderToolbarActions(tab: tab,
                        newTab: { workspace.open(URL(string: "https://news.ycombinator.com/")!) },
                        openLink: { showOpen = true })
                }
            }
            #else
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.open(URL(string: "https://news.ycombinator.com/")!) } label: { Label("New tab", systemImage: "plus") }
                    .labelStyle(.iconOnly)
                    .help("New tab (⌘T)")
                    .keyboardShortcut("t", modifiers: .command)
                Button { showOpen = true } label: {
                    Label("Open a link in HackerViews", systemImage: "tray.and.arrow.down")
                }
                    .labelStyle(.iconOnly)
                    .symbolRenderingMode(.monochrome)
                    .help("Open a Hacker News link in HackerViews (⌘L)")
                    .keyboardShortcut("l", modifiers: .command)
            }
            #endif
        }
        .alert("Open a Hacker News link", isPresented: $showOpen) {
            TextField("https://news.ycombinator.com/item?id=…", text: $address)
            Button("Open") {
                let text = address.trimmingCharacters(in: .whitespacesAndNewlines)
                if let url = URL(string: text), BrowserTab.isHN(url) { workspace.open(url); address = "" }
                else { linkError = true }
            }
            Button("Cancel", role: .cancel) {}
        } message: { Text("Paste a story, comment, or profile link. Your filters apply before the page appears.") }
        .alert("Use an HTTPS link to news.ycombinator.com", isPresented: $linkError) { Button("OK", role: .cancel) {} }
    }
}

private struct TabChip: View {
    @ObservedObject var tab: BrowserTab
    let selected: Bool
    let select: () -> Void
    let close: () -> Void
    var body: some View {
        HStack(spacing: 0) {
            Button(action: select) {
                Text(tab.title).lineLimit(1).frame(maxWidth: 180)
            }.buttonStyle(ControlSurfaceStyle())
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }
                .buttonStyle(ControlSurfaceStyle()).accessibilityLabel("Close \(tab.title)")
                .help("Close tab")
        }
        .background(selected ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BrowserPage: View {
    @ObservedObject var tab: BrowserTab
    @State private var showExcerpt = false
    @State private var showingFind = false
    @State private var findQuery = ""
    @State private var findFailed = false
    @State private var findGeneration = 0
    @FocusState private var findFocused: Bool

    private func search(backwards: Bool = false) {
        findGeneration += 1
        let generation = findGeneration
        findFailed = false
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        tab.webView.find(findQuery, configuration: configuration) { result in
            guard generation == findGeneration else { return }
            findFailed = !findQuery.isEmpty && !result.matchFound
        }
    }

    private func showFind() {
        showingFind = true
        findFocused = true
    }

    private func closeFind() {
        showingFind = false
        findFocused = false
        findGeneration += 1
        tab.webView.find("", configuration: WKFindConfiguration()) { _ in }
        #if os(macOS)
        tab.webView.window?.makeFirstResponder(tab.webView)
        #endif
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Find in page", text: $findQuery)
                .textFieldStyle(.roundedBorder)
                .focused($findFocused)
                .onSubmit { search() }
                .onChange(of: findQuery) { _, _ in search() }
                .frame(maxWidth: 320)
            if findFailed { Text("No matches").font(.caption).foregroundStyle(.secondary) }
            Spacer()
            Button { search(backwards: true) } label: { Image(systemName: "chevron.up") }
                .help("Previous match (⇧⌘G)").accessibilityLabel("Previous match")
                .disabled(findQuery.isEmpty)
            Button { search() } label: { Image(systemName: "chevron.down") }
                .help("Next match (⌘G)").accessibilityLabel("Next match")
                .disabled(findQuery.isEmpty)
            Button("Done", action: closeFind)
        }
        .buttonStyle(ControlSurfaceStyle())
        .padding(8)
        .background(.bar)
        #if os(macOS)
        .onExitCommand(perform: closeFind)
        #endif
    }

    var body: some View {
        VStack(spacing: 0) {
            if showingFind { findBar; Divider() }
            if tab.destinationHidden && !tab.revealedDestination {
                HStack {
                    Text("This contribution is hidden by your filters.").font(.caption)
                    Spacer()
                    Button("Reveal this contribution", action: tab.revealDestination)
                }.padding(10)
            }
            if tab.revealedDestination {
                HStack {
                    Text("Temporarily revealing this contribution. Other filtered content stays hidden.").font(.caption)
                    Spacer()
                    Button("Hide again", action: tab.reload)
                }.padding(10)
            }
            if !tab.savedReferences.isEmpty {
                HStack {
                    Button("View saved excerpt") { showExcerpt = true }
                    Spacer()
                }.padding(10)
            }
            if tab.unresolvedCount > 0 && tab.state == .ready {
                HStack {
                    Text("\(tab.unresolvedCount) items hidden because account or ancestry checks couldn’t be completed.").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Retry", action: tab.retry).font(.caption)
                }.padding(10)
            }
            ZStack {
                WebSurface(tab: tab)
                    .opacity(tab.state == .ready ? 1 : 0)
                    .allowsHitTesting(tab.state == .ready)
                    .accessibilityHidden(tab.state != .ready)
                if tab.state == .loading, let snapshot = tab.navigationSnapshot {
                    GeometryReader { geometry in
                        #if os(macOS)
                        Image(nsImage: snapshot)
                            .resizable().frame(width: geometry.size.width, height: geometry.size.height)
                        #else
                        Image(uiImage: snapshot)
                            .resizable().frame(width: geometry.size.width, height: geometry.size.height)
                        #endif
                    }
                    .allowsHitTesting(false).accessibilityHidden(true)
                } else if tab.state != .ready {
                    status.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background)
                }
            }
            HStack {
                Spacer()
                Text(tab.state == .ready && tab.hiddenCount > 0 ? "\(tab.hiddenCount) hidden" : "")
                    .font(.caption).foregroundStyle(.secondary)
                    .help("Page elements hidden by your filters")
            }
            .padding(.horizontal, 12)
            .frame(height: 24)
            .background(.bar)
        }
        #if os(macOS)
        .navigationTitle(tab.url.flatMap(BrowserTab.topicID) != nil ? (tab.threadTitle ?? "") : "")
        .focusedSceneObject(tab)
        .focusedSceneValue(\.pageFind, PageFindActions(
            show: showFind,
            next: { showFind(); search() },
            previous: { showFind(); search(backwards: true) }))
        #endif
        .sheet(isPresented: $showExcerpt) {
            NavigationStack {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(tab.savedReferences) { reference in
                            Text(reference.context).font(.headline)
                            Text(reference.excerpt.isEmpty ? "No excerpt was saved." : reference.excerpt).textSelection(.enabled)
                            if !reference.annotation.isEmpty { Text(reference.annotation).textSelection(.enabled) }
                        }
                    }.padding()
                }
                .navigationTitle("Saved excerpt")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { showExcerpt = false } } }
            }
            #if os(macOS)
            .frame(width: 580, height: 460)
            #endif
        }
        .toolbar {
            #if os(iOS)
            ToolbarItemGroup(placement: .navigation) {
                Button(action: tab.back) { Label("Back", systemImage: "chevron.left") }
                    .disabled(!tab.canGoBack).help("Back")
                Button(action: tab.forward) { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!tab.canGoForward).help("Forward")
            }
            #endif
            #if os(iOS)
            ToolbarItemGroup(placement: .primaryAction) {
                Button(action: tab.openInBrowser) {
                    Label("Open in default browser", systemImage: "arrow.up.forward.square")
                }
                    .labelStyle(.iconOnly)
                    .symbolRenderingMode(.monochrome)
                    .help("Open this page in your default browser")
                Button(action: tab.reload) { Label("Reload", systemImage: "arrow.clockwise") }
                    .labelStyle(.iconOnly)
                    .help("Reload (⌘R)").keyboardShortcut("r", modifiers: .command)
            }
            #endif
        }
    }
    @ViewBuilder private var status: some View {
        switch tab.state {
        case .loading:
            ProgressView("Loading page…")
        case .blocked:
            VStack(spacing: 16) {
                ContentUnavailableView("This contribution is blocked", systemImage: "hand.raised",
                    description: Text(tab.blockingReason.isEmpty ? "A filter hides this contribution or its ancestor." : "Hidden by " + tab.blockingReason))
                Button("Reveal this contribution", action: tab.revealDestination)
                    .buttonStyle(.borderedProminent).padding(.bottom, 30)
            }
        case .unresolved:
            VStack {
                ContentUnavailableView("Ancestry couldn’t be verified", systemImage: "network.slash", description: Text("A parent comment is unavailable, deleted, or missing its author. This page stays hidden to honor your blocks."))
                Button("Retry checks", action: tab.retry).buttonStyle(.borderedProminent).padding(.bottom, 40)
            }
        case .failed(let message):
            VStack {
                ContentUnavailableView("Couldn’t load this page", systemImage: "wifi.exclamationmark", description: Text(message))
                Button("Reload", action: tab.reload).buttonStyle(.borderedProminent).padding(.bottom, 40)
            }
        case .ready: EmptyView()
        }
    }
}


/// Padding belongs to the button surface so its visual and interactive bounds agree.
struct ControlSurfaceStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        Surface(configuration: configuration)
    }
    private struct Surface: View {
        let configuration: ButtonStyle.Configuration
        @State private var hovering = false
        @Environment(\.isEnabled) private var enabled
        @Environment(\.isFocused) private var focused
        private var targetSize: CGFloat {
            #if os(macOS)
            32
            #else
            44
            #endif
        }
        var body: some View {
            configuration.label
                .padding(.horizontal, 8)
                .frame(minWidth: targetSize, minHeight: targetSize)
                .contentShape(Rectangle())
                .background(enabled && (hovering || configuration.isPressed) ? Color.primary.opacity(configuration.isPressed ? 0.18 : 0.08) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6))
                .overlay {
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(focused ? Color.accentColor : Color.clear, lineWidth: 2)
                }
                .opacity(enabled ? 1 : 0.45)
                .onHover { hovering = $0 }
        }
    }
}


#if os(macOS)
struct PageFindActions {
    var show: () -> Void
    var next: () -> Void
    var previous: () -> Void
}

private struct PageFindKey: FocusedValueKey {
    typealias Value = PageFindActions
}

extension FocusedValues {
    var pageFind: PageFindActions? {
        get { self[PageFindKey.self] }
        set { self[PageFindKey.self] = newValue }
    }
}

struct ReaderNavigationCommands: Commands {
    @FocusedObject private var workspace: BrowserWorkspace?
    @FocusedObject private var tab: BrowserTab?
    private var hasSheet: Bool { NSApp.keyWindow?.attachedSheet != nil || NSApp.keyWindow?.sheetParent != nil }
    private var closesTab: Bool { !hasSheet && (workspace?.tabs.count ?? 0) > 1 }
    var body: some Commands {
        CommandGroup(replacing: .saveItem) {
            Button(closesTab ? "Close Tab" : "Close Window") {
                if closesTab { _ = workspace?.closeSelectedTab() }
                else { NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil) }
            }
            .keyboardShortcut("w", modifiers: .command)
            if closesTab {
                Button("Close Window") { NSApp.sendAction(#selector(NSWindow.performClose(_:)), to: nil, from: nil) }
                    .keyboardShortcut("w", modifiers: [.command, .shift])
            }
        }
        CommandMenu("History") {
            Button("Back") { if !hasSheet { tab?.back() } }
                .keyboardShortcut("[", modifiers: .command)
                .disabled(hasSheet || tab?.canGoBack != true)
            Button("Forward") { if !hasSheet { tab?.forward() } }
                .keyboardShortcut("]", modifiers: .command)
                .disabled(hasSheet || tab?.canGoForward != true)
        }
    }
}

struct PageFindCommands: Commands {
    @FocusedValue(\.pageFind) private var find
    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Divider()
            Button("Find in Page…") { find?.show() }
                .keyboardShortcut("f", modifiers: .command)
                .disabled(find == nil)
            Button("Find Next") { find?.next() }
                .keyboardShortcut("g", modifiers: .command)
                .disabled(find == nil)
            Button("Find Previous") { find?.previous() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(find == nil)
        }
    }
}
#endif


#if os(macOS)
private struct ReaderToolbarActions: View {
    @ObservedObject var tab: BrowserTab
    let newTab: () -> Void
    let openLink: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            Button(action: tab.back) { Label("Back", systemImage: "chevron.left") }
                .disabled(!tab.canGoBack).help("Back")
            Button(action: tab.forward) { Label("Forward", systemImage: "chevron.right") }
                .disabled(!tab.canGoForward).help("Forward")
            separator
            Button(action: newTab) { Label("New tab", systemImage: "plus") }
                .help("New tab (⌘T)").keyboardShortcut("t", modifiers: .command)
            Button(action: tab.reload) { Label("Reload", systemImage: "arrow.clockwise") }
                .help("Reload (⌘R)").keyboardShortcut("r", modifiers: .command)
            separator
            Button(action: openLink) { Label("Open a link in HackerViews", systemImage: "tray.and.arrow.down") }
                .help("Open a Hacker News link in HackerViews (⌘L)")
                .keyboardShortcut("l", modifiers: .command)
            Button(action: tab.openInBrowser) { Label("Open in default browser", systemImage: "arrow.up.forward.square") }
                .help("Open this page in your default browser")
        }
        .labelStyle(.iconOnly)
        .symbolRenderingMode(.monochrome)
    }

    private var separator: some View {
        Divider().frame(height: 16).padding(.horizontal, 3).accessibilityHidden(true)
    }
}
#endif
