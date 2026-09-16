import SwiftUI

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
        .navigationTitle("Quiet HN")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { workspace.open(URL(string: "https://news.ycombinator.com/")!) } label: { Label("New tab", systemImage: "plus") }
                    .keyboardShortcut("t", modifiers: .command)
                Button { showOpen = true } label: { Label("Open HN link", systemImage: "link") }
                    .keyboardShortcut("l", modifiers: .command)
            }
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
        HStack(spacing: 8) {
            Button(action: select) { Text(tab.title).lineLimit(1).frame(maxWidth: 180) }.buttonStyle(.plain)
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }.buttonStyle(.plain).accessibilityLabel("Close \(tab.title)")
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
        .background(selected ? Color.orange.opacity(0.14) : Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct BrowserPage: View {
    @ObservedObject var tab: BrowserTab
    var body: some View {
        VStack(spacing: 0) {
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
                if tab.state != .ready { status.frame(maxWidth: .infinity, maxHeight: .infinity).background(.background) }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .navigation) {
                Button(action: tab.back) { Label("Back", systemImage: "chevron.left") }
                    .disabled(!tab.canGoBack).help("Back")
                Button(action: tab.forward) { Label("Forward", systemImage: "chevron.right") }
                    .disabled(!tab.canGoForward).help("Forward")
            }
            ToolbarItemGroup(placement: .primaryAction) {
                if tab.hiddenCount > 0 {
                    Label("\(tab.hiddenCount)", systemImage: "hand.raised")
                        .font(.caption).foregroundStyle(.secondary)
                        .help("\(tab.hiddenCount) page elements hidden")
                }
                Button(action: tab.reload) { Label("Reload", systemImage: "arrow.clockwise") }
                    .help("Reload").keyboardShortcut("r", modifiers: .command)
            }
        }
    }
    @ViewBuilder private var status: some View {
        switch tab.state {
        case .loading:
            VStack(spacing: 14) { ProgressView(); Text("Loading your filtered HN…").foregroundStyle(.secondary) }
        case .blocked:
            ContentUnavailableView("This branch is blocked", systemImage: "hand.raised", description: Text("Its author or an ancestor matches an individual block or an account filter. Review the ordered rules in Filters."))
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
