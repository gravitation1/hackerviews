import SwiftUI

@MainActor
final class BrowserWorkspace: ObservableObject {
    @Published var tabs: [BrowserTab] = []
    @Published var selectedID: UUID? {
        didSet {
            if !restoring { selected?.activateRestoredPage() }
            saveSession()
        }
    }
    private struct SavedTab: Codable {
        var url: URL
        var title: String
        var scrollY: Double
        var history: [BrowserTab.HistoryEntry]?
        var historyIndex: Int?
    }
    private struct Session: Codable {
        var tabs: [SavedTab]
        var selected: Int
    }
    private let defaults: UserDefaults
    private let sessionKey = "HackerViews.readerSession"
    private var restoring = false
    private var started = false
    @Published var draft: RecordDraft?
    private let store: RecordStore
    private let service = HNService.shared
    var selected: BrowserTab? { tabs.first { $0.id == selectedID } }
    init(store: RecordStore, defaults: UserDefaults = .standard) {
        self.store = store
        self.defaults = defaults
    }
    func start() {
        guard !started else {
            if tabs.isEmpty { open(URL(string: "https://news.ycombinator.com/")!) }
            return
        }
        started = true
        if !tabs.isEmpty { saveSession(); return }
        if let data = defaults.data(forKey: sessionKey),
           let session = try? JSONDecoder().decode(Session.self, from: data) {
            restoring = true
            for saved in session.tabs.prefix(100) where BrowserTab.isHN(saved.url) {
                let tab = makeTab()
                tab.title = saved.title
                tab.scrollY = saved.scrollY.isFinite ? max(0, saved.scrollY) : 0
                tab.restoreScrollY = tab.scrollY
                if let history = saved.history, let index = saved.historyIndex {
                    tab.restoreHistory(history, index: index)
                }
                tabs.append(tab)
                tab.prepareRestoredPage(saved.url)
            }
            if !tabs.isEmpty { selectedID = tabs[min(max(0, session.selected), tabs.count - 1)].id }
            restoring = false
            selected?.activateRestoredPage()
        }
        if tabs.isEmpty { open(URL(string: "https://news.ycombinator.com/")!) }
    }
    func saveSession() {
        guard started, !restoring else { return }
        #if DEBUG
        let traceStart = ProcessInfo.processInfo.systemUptime
        defer {
            ReaderTrace.event("session.save", ["ms": (ProcessInfo.processInfo.systemUptime - traceStart) * 1000, "count": tabs.count])
        }
        #endif
        let saved = tabs.compactMap { tab -> SavedTab? in
            guard let url = tab.url, BrowserTab.isHN(url) else { return nil }
            return SavedTab(url: url, title: tab.title, scrollY: tab.scrollY, history: tab.savedHistory, historyIndex: tab.historyIndex)
        }
        let session = Session(tabs: saved, selected: tabs.firstIndex { $0.id == selectedID } ?? 0)
        if let data = try? JSONEncoder().encode(session) { defaults.set(data, forKey: sessionKey) }
    }
    private func makeTab() -> BrowserTab {
        let tab = BrowserTab(store: store, service: service, retainsPages: true)
        tab.onRecord = { [weak self] in self?.draft = $0 }
        tab.onOpenTab = { [weak self] url, select in self?.open(url, select: select) }
        tab.onSessionChange = { [weak self] in self?.saveSession() }
        return tab
    }
    func open(_ url: URL, newTab: Bool = true, select: Bool = true) {
        guard BrowserTab.isHN(url) else { return }
        if !newTab, let selected { selected.load(url); return }
        let tab = makeTab()
        tabs.append(tab); tab.load(url)
        if select || selectedID == nil { selectedID = tab.id }
        saveSession()
    }
    /// The close command leaves the last tab intact so closing the window keeps
    /// its reading session available for restoration.
    @discardableResult
    func closeSelectedTab() -> Bool {
        guard tabs.count > 1, let selected else { return false }
        close(selected)
        return true
    }
    func close(_ tab: BrowserTab) {
        let index = tabs.firstIndex { $0.id == tab.id } ?? 0
        tabs.removeAll { $0.id == tab.id }
        if selectedID == tab.id { selectedID = tabs.isEmpty ? nil : tabs[min(index, tabs.count - 1)].id }
        start()
        saveSession()
    }
}
