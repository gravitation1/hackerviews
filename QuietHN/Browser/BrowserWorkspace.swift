import SwiftUI

@MainActor
final class BrowserWorkspace: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedID: UUID?
    @Published var draft: RecordDraft?
    private let store: RecordStore
    private let service = HNService()
    var selected: BrowserTab? { tabs.first { $0.id == selectedID } }
    init(store: RecordStore) { self.store = store }
    func start() { if tabs.isEmpty { open(URL(string: "https://news.ycombinator.com/")!) } }
    func open(_ url: URL, newTab: Bool = true) {
        guard BrowserTab.isHN(url) else { return }
        if !newTab, let selected { selected.load(url); return }
        let tab = BrowserTab(store: store, service: service)
        tab.onRecord = { [weak self] in self?.draft = $0 }
        tab.onOpenTab = { [weak self] in self?.open($0) }
        tabs.append(tab); selectedID = tab.id; tab.load(url)
    }
    func close(_ tab: BrowserTab) {
        let index = tabs.firstIndex { $0.id == tab.id } ?? 0
        tabs.removeAll { $0.id == tab.id }
        if selectedID == tab.id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        start()
    }
}
