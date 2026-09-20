import SwiftUI
import WebKit
import Combine

struct RecordDraft: Identifiable {
    var id = UUID()
    var username: String
    var citation: Citation?
    var prefer = false
    var block = false
    var filtersOnly = false
}

#if os(macOS)
typealias NavigationImage = NSImage
#else
typealias NavigationImage = UIImage
#endif

enum PageState: Equatable {
    case loading, ready, blocked, unresolved, failed(String)
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    @Published private(set) var activePage: BrowserTab?
    private let retainsPages: Bool
    private weak var historyOwner: BrowserTab?
    private var retainedPages: [Int: BrowserTab] = [:]
    private var pageSubscription: AnyCancellable?
    private var reactivationPosition: (Double, [String: Any]?)?
    private var restoringRetainedViewport = false
    var displayedPage: BrowserTab { activePage ?? self }

    @Published var title = "Hacker News"
    @Published var threadTitle: String?
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var state: PageState = .loading
    @Published private(set) var navigationSnapshot: NavigationImage?
    private var lazyURL: URL?
    private var shellNavigation = false
    private var canonicalTopicURL: URL?
    private var pendingFormSubmission = false
    private var networkWaiters: [Int: Task<Void, Never>] = [:]
    private var networkLeases = Set<Int>()
    private var lazyTasks: [Int: Task<Void, Never>] = [:]
    private var captureID = UUID()
    private var presenting = false
    private var readinessID = UUID()
    @Published var destinationHidden = false
    @Published var revealedDestination = false
    /// A discussion the reader is about to open from a temporarily revealed
    /// contribution. The topic shell opens it revealed instead of asking again.
    private var pendingReveal: (id: Int, at: Date)?
    @Published var blockingReason = ""
    var savedReferences: [Citation] {
        guard let url = webView.url ?? url else { return [] }
        return store.people.flatMap(\.citations).filter { $0.url == url.absoluteString }
    }
    func revealDestination() {
        revealedDestination = true
        webView.callAsyncJavaScript("window.HackerViews?.revealDestination()", arguments: [:], in: nil, in: Self.world, completionHandler: nil)
    }
    /// Takes the pending reveal for `id` from this tab and its history owner.
    /// A reveal older than a few seconds belonged to a navigation that never
    /// happened in this tab, such as a link opened in a new tab.
    private func consumePendingReveal(for id: Int) -> Bool {
        var matched = false
        for tab in [self, historyOwner].compactMap({ $0 }) {
            guard let pending = tab.pendingReveal else { continue }
            let fresh = Date().timeIntervalSince(pending.at) < 10
            // An intent for another discussion stays for the navigation it belongs to.
            if pending.id == id || !fresh { tab.pendingReveal = nil }
            if pending.id == id && fresh { matched = true }
        }
        return matched
    }
    func openInBrowser() {
        guard let url = webView.url ?? url else { return }
        #if os(macOS)
        ExternalBrowser.open(url)
        #else
        UIApplication.shared.open(url)
        #endif
    }
    @Published var hiddenCount = 0
    @Published var unresolvedCount = 0
    struct HistoryEntry: Codable, Equatable {
        var url: URL
        var scrollY: Double = 0
        var anchor: Data? = nil
        var collapsed: [Int]? = nil
        var restorationAnchor: [String: Any]? {
            var value = anchor.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
            if let collapsed { value["collapsed"] = collapsed }
            return value.isEmpty ? nil : value
        }
    }
    private(set) var history: [HistoryEntry] = []
    private(set) var historyIndex = -1
    var scrollY: Double = 0 { didSet { if retainsPages { activePage?.scrollY = scrollY } } }
    var restoreScrollY: Double?
    private var refreshAnchor: [String: Any]?
    var onSessionChange: (() -> Void)?
    var onRecord: ((RecordDraft) -> Void)?
    var onOpenTab: ((URL, Bool) -> Void)?
    private let store: RecordStore
    private let service: HNService
    private let persistentSession: Bool
    private var subscription: AnyCancellable?
    private var recordSubscription: AnyCancellable?
    private var navigationID = UUID()
    private var timeout: Task<Void, Never>?
    private static let world = WKContentWorld.world(name: "HackerViews")

    private var createdWebView = false
    var hasCreatedWebView: Bool { activePage?.hasCreatedWebView ?? createdWebView }
    var webView: WKWebView { activePage?.webView ?? ownedWebView }
    private lazy var ownedWebView: WKWebView = {
        createdWebView = true
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = persistentSession ? .default() : .nonPersistent()
        configuration.userContentController.add(WeakMessageHandler(self), contentWorld: Self.world, name: "hackerViews")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        #if os(macOS)
        // History swipes can capture diagonal trackpad gestures before vertical
        // scrolling starts, even when the document has no horizontal overflow.
        view.allowsBackForwardNavigationGestures = false
        #else
        view.allowsBackForwardNavigationGestures = true
        #endif
        view.underPageBackgroundColor = .clear
        #if os(iOS)
        view.isOpaque = false
        view.backgroundColor = .clear
        #endif
        installScripts(in: view)
        return view
    }()

    init(store: RecordStore, service: HNService, persistentSession: Bool = true, retainsPages: Bool = false) {
        self.store = store; self.service = service; self.persistentSession = persistentSession
        self.retainsPages = retainsPages
        super.init()
        guard !retainsPages else { return }
        subscription = store.$archive.map(\.policy).removeDuplicates().dropFirst().sink { [weak self] policy in
            guard let self, self.pendingRestoredURL == nil else { return }
            self.installScripts(in: self.webView, policy: policy)
            self.webView.callAsyncJavaScript("window.HackerViews?.setOrdered(active, true)",
                arguments: ["active": policy.rules.contains { $0.isActive }],
                in: nil, in: Self.world, completionHandler: nil)
        }
        recordSubscription = store.$archive.dropFirst().sink { [weak self] archive in
            guard let self, self.pendingRestoredURL == nil, let url = self.webView.url, url.path == "/user",
                  let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value else { return }
            self.sendProfileRecord(name, archive: archive)
        }

    }

    private(set) var pendingRestoredURL: URL?
    func prepareRestoredPage(_ target: URL) {
        guard Self.isHN(target) else { return }
        recordNavigation(target)
        pendingRestoredURL = target
    }
    func activateRestoredPage() {
        guard let target = pendingRestoredURL else { return }
        load(target)
    }
    func load(_ url: URL) {
        guard Self.isHN(url) else { return }
        if retainsPages {
            captureActivePosition()
            pendingRestoredURL = nil
            recordNavigation(url)
            retainedPages = retainedPages.filter { $0.key <= historyIndex }
            activateHistoryPage(reload: true)
            return
        }
        pendingRestoredURL = nil
        pendingFormSubmission = false
        recordNavigation(url)
        if Self.topicID(url) != nil { loadTopic(url) }
        else { lazyURL = nil; pendingReveal = nil; webView.load(URLRequest(url: url)) }
    }
    static func topicID(_ url: URL) -> Int? {
        guard isHN(url), url.path == "/item",
              let raw = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
              let id = Int(raw), id > 0 else { return nil }
        return id
    }
    private func cancelNetworkLeases() {
        networkWaiters.values.forEach { $0.cancel() }; networkWaiters.removeAll()
        let count = networkLeases.count; networkLeases.removeAll()
        Task { for _ in 0..<count { await ReaderRequestPool.shared.release() } }
    }
    private func loadTopic(_ target: URL) {
        guard let id = Self.topicID(target) else { return }
        lazyTasks.values.forEach { $0.cancel() }; lazyTasks.removeAll()
        cancelNetworkLeases()
        lazyURL = target
        threadTitle = nil
        shellNavigation = true
        url = target
        let y = restoreScrollY ?? 0
        restoreScrollY = nil
        let anchorData = refreshAnchor.flatMap { try? JSONSerialization.data(withJSONObject: $0) }?.base64EncodedString() ?? ""
        refreshAnchor = nil
        navigationSnapshot = nil
        state = .loading
        let reveal = consumePendingReveal(for: id) ? " data-hv-reveal=\"1\"" : ""
        webView.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Hacker News</title>
        <link rel="stylesheet" href="https://news.ycombinator.com/news.css"></head>
        <body data-hv-topic="\(id)" data-hv-scroll="\(y)" data-hv-anchor="\(anchorData)"\(reveal)><main id="hv-topic">
        <header id="hv-header" class="hv-header"></header>
        <div id="hv-topic-root"></div></main></body></html>
        """, baseURL: target)
    }
    func restoreHistory(_ entries: [HistoryEntry], index: Int) {
        guard !entries.isEmpty, entries.indices.contains(index),
              entries.allSatisfy({ Self.isHN($0.url) && $0.scrollY.isFinite && $0.scrollY >= 0 }) else { return }
        history = entries
        historyIndex = index
        refreshAnchor = entries[index].restorationAnchor
        updateHistoryButtons()
    }
    func recordNavigation(_ target: URL) {
        guard Self.isHN(target) else { return }
        if history.indices.contains(historyIndex), history[historyIndex].url == target {
            url = target
            updateHistoryButtons()
            return
        }
        if history.indices.contains(historyIndex) { history[historyIndex].scrollY = scrollY }
        history = Array(history.prefix(historyIndex + 1))
        scrollY = restoreScrollY ?? 0
        history.append(HistoryEntry(url: target, scrollY: scrollY))
        historyIndex = history.count - 1
        url = target
        updateHistoryButtons()
        onSessionChange?()
    }
    func saveReadingPosition(y: Double, anchor: [String: Any]?) {
        if let activePage { activePage.saveReadingPosition(y: y, anchor: anchor); return }
        if restoringRetainedViewport { return }
        if let historyOwner, historyOwner.activePage !== self { return }
        guard y.isFinite, y >= 0 else { return }
        scrollY = y
        if history.indices.contains(historyIndex) {
            history[historyIndex].scrollY = y
            if let anchor, let id = anchor["id"] as? Int, id > 0,
               let top = anchor["top"] as? Double, top.isFinite,
               let ancestors = anchor["ancestors"] as? [Int], ancestors.count <= 512,
               ancestors.allSatisfy({ $0 > 0 }) {
                history[historyIndex].anchor = try? JSONSerialization.data(withJSONObject:
                    ["id": id, "top": top, "y": y, "ancestors": ancestors])
            } else { history[historyIndex].anchor = nil }
        }
        onSessionChange?()
    }
    func saveCollapsedThreads(_ ids: [Int]) {
        if let activePage { activePage.saveCollapsedThreads(ids); return }
        if let historyOwner, historyOwner.activePage !== self { return }
        guard history.indices.contains(historyIndex), ids.count <= 100_000,
              ids.allSatisfy({ $0 > 0 }) else { return }
        history[historyIndex].collapsed = Array(Set(ids)).sorted()
        onSessionChange?()
    }
    var savedHistory: [HistoryEntry] {
        var entries = history
        if entries.indices.contains(historyIndex) { entries[historyIndex].scrollY = scrollY }
        return entries
    }
    private func updateHistoryButtons() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex >= 0 && historyIndex + 1 < history.count
    }
    func back() { if let historyOwner { historyOwner.back() } else { travel(to: historyIndex - 1) } }
    func forward() { if let historyOwner { historyOwner.forward() } else { travel(to: historyIndex + 1) } }
    private func travel(to index: Int) {
        guard history.indices.contains(index) else { return }
        if retainsPages { captureActivePosition() }
        pendingRestoredURL = nil
        pendingFormSubmission = false
        if history.indices.contains(historyIndex) { history[historyIndex].scrollY = scrollY }
        historyIndex = index
        scrollY = history[index].scrollY
        restoreScrollY = scrollY
        refreshAnchor = history[index].restorationAnchor
        url = history[index].url
        updateHistoryButtons()
        onSessionChange?()
        if retainsPages { activateHistoryPage(); return }
        if Self.topicID(history[index].url) != nil { loadTopic(history[index].url) }
        else { lazyURL = nil; webView.load(URLRequest(url: history[index].url)) }
    }
    private func captureActivePosition() {
        guard let page = activePage, !page.restoringRetainedViewport, history.indices.contains(historyIndex) else { return }
        let index = historyIndex
        history[index].scrollY = page.scrollY
        page.webView.callAsyncJavaScript("return window.HackerViews?.readingPosition() ?? {y: window.scrollY}",
            arguments: [:], in: nil, in: Self.world) { [weak self, weak page] result in
                guard let self, let page, self.retainedPages[index] === page,
                      self.history.indices.contains(index), case .success(let value) = result,
                      let position = value as? [String: Any], let y = position["y"] as? Double,
                      y.isFinite, y >= 0 else { return }
                self.history[index].scrollY = y
                self.history[index].anchor = try? JSONSerialization.data(withJSONObject: position)
                page.scrollY = y
                if page.history.indices.contains(page.historyIndex) {
                    page.history[page.historyIndex].scrollY = y
                    page.history[page.historyIndex].anchor = self.history[index].anchor
                }
                page.reactivationPosition = (y, position)
                if self.activePage === page { page.restoreRetainedViewport() }
                self.onSessionChange?()
            }
    }

    private func activateHistoryPage(reload: Bool = false) {
        let index = historyIndex
        guard history.indices.contains(index) else { return }
        let entry = history[index]
        let page: BrowserTab
        if !reload, let retained = retainedPages[index] {
            page = retained
            page.reactivationPosition = (entry.scrollY, entry.restorationAnchor)
        } else {
            page = BrowserTab(store: store, service: service, persistentSession: persistentSession)
            page.title = title
            page.historyOwner = self
            page.restoreScrollY = entry.scrollY
            page.refreshAnchor = entry.restorationAnchor
            page.onRecord = { [weak self] in self?.onRecord?($0) }
            page.onOpenTab = { [weak self] url, select in self?.onOpenTab?(url, select) }
            page.onSessionChange = { [weak self, weak page] in
                guard let self, let page, self.activePage === page else { return }
                self.synchronizePage(page)
                self.onSessionChange?()
            }
            retainedPages[index] = page
            page.pendingReveal = pendingReveal; pendingReveal = nil
            page.load(entry.url)
            if page.history.indices.contains(page.historyIndex) { page.history[page.historyIndex].collapsed = entry.collapsed }
        }
        activePage = page
        restoreScrollY = nil
        refreshAnchor = nil
        synchronizePage(page)
        pageSubscription = page.objectWillChange.sink { [weak self, weak page] in
            Task { @MainActor in
                guard let self, let page, self.activePage === page else { return }
                self.synchronizePage(page)
            }
        }
    }

    private func synchronizePage(_ page: BrowserTab) {
        guard history.indices.contains(historyIndex) else { return }
        title = page.title; threadTitle = page.threadTitle; state = page.state
        hiddenCount = page.hiddenCount; unresolvedCount = page.unresolvedCount
        if let pageURL = page.url { url = pageURL; history[historyIndex].url = pageURL }
        scrollY = page.scrollY
        history[historyIndex].scrollY = page.scrollY
        if let position = page.savedHistory.last?.anchor { history[historyIndex].anchor = position }
        history[historyIndex].collapsed = page.savedHistory.last?.collapsed
        if page.canGoBack != canGoBack { page.canGoBack = canGoBack }
        if page.canGoForward != canGoForward { page.canGoForward = canGoForward }
    }

    func restoreRetainedViewport() {
        guard let (y, anchor) = reactivationPosition else { return }
        reactivationPosition = nil
        restoringRetainedViewport = true
        webView.callAsyncJavaScript("await new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r))); if (window.HackerViews) window.HackerViews.restoreReadingPosition(anchor, y); else window.scrollTo(0, y)",
            arguments: ["anchor": anchor ?? [:], "y": y], in: nil, in: Self.world) { [weak self] _ in
                self?.restoringRetainedViewport = false
            }
    }

    func scrollToTop() {
        if let activePage { activePage.scrollToTop(); return }
        restoreScrollY = nil
        refreshAnchor = nil
        webView.callAsyncJavaScript("window.scrollTo({top: 0, left: 0, behavior: 'instant'})",
                                   arguments: [:], in: nil, in: Self.world, completionHandler: nil)
    }
    func reload() {
        if let activePage { activePage.reload(); return }
        let epoch = navigationID
        webView.callAsyncJavaScript("return window.HackerViews?.refreshState() ?? window.HackerViews?.readingPosition() ?? {y: window.scrollY}",
                                   arguments: [:], in: nil, in: Self.world) { [weak self] result in
            guard let self, navigationID == epoch else { return }
            if case .success(let value) = result, let anchor = value as? [String: Any],
               let y = anchor["y"] as? Double, y.isFinite, y >= 0 {
                scrollY = y
                refreshAnchor = anchor
            }
            restoreScrollY = scrollY
            if let lazyURL { loadTopic(lazyURL) } else { webView.reload() }
        }
    }
    func retry() {
        state = .loading; armTimeout()
        webView.callAsyncJavaScript("window.HackerViews?.retry()", arguments: [:], in: nil, in: Self.world, completionHandler: nil)
    }

    static func isHN(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "news.ycombinator.com" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
    }

    private func presentReadyPage() {
        guard state != .ready, !presenting else { return }
        presenting = true
        let epoch = navigationID
        let readiness = readinessID
        // The bridge reports readiness during DOM mutation. Wait for layout and
        // a paint opportunity before replacing the outgoing-page snapshot.
        webView.callAsyncJavaScript("await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
                                    arguments: [:], in: nil, in: Self.world) { [weak self] result in
            guard let self, self.navigationID == epoch, self.readinessID == readiness else { return }
            self.presenting = false
            guard self.state == .loading, case .success = result else { return }
            self.state = .ready
            self.navigationSnapshot = nil
        }
    }

    private func installScripts(in view: WKWebView, policy: FilterPolicy? = nil) {
        let policy = policy ?? store.archive.policy
        let data = (try? JSONEncoder().encode(Array(policy.blocked))) ?? Data("[]".utf8)
        let names = String(decoding: data, as: UTF8.self)
        let preferred = String(decoding: (try? JSONEncoder().encode(Array(policy.preferred))) ?? Data("[]".utf8), as: UTF8.self)
        let scriptURL = Bundle.main.url(forResource: "filter", withExtension: "js")
        let script = scriptURL.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? ""
        let controller = view.configuration.userContentController
        controller.removeAllUserScripts()
        #if DEBUG
        let diagnostics = "window.__hackerViewsScrollDiagnostics = true; "
        #else
        let diagnostics = ""
        #endif
        controller.addUserScript(WKUserScript(source: diagnostics + "window.__hackerViewsNetworkPool = true; window.__hackerViewsOrdered = true; window.__hackerViewsOrderedActive = \(policy.rules.contains { $0.isActive }); window.__hackerViewsBlocked = \(names); window.__hackerViewsAccountFiltersActive = \(policy.accounts.isActive); window.__hackerViewsPreferred = \(preferred); window.__hackerViewsHighlightActive = \(policy.highlights.isActive);\n" + script,
                                              injectionTime: .atDocumentStart, forMainFrameOnly: true, in: Self.world))
    }

    private func armTimeout() {
        timeout?.cancel()
        timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(35))
            guard !Task.isCancelled, let self, self.state == .loading else { return }
            self.state = .failed("The page or its ancestry checks took too long. Your filters remain active.")
        }
    }

    fileprivate func receive(_ message: WKScriptMessage) {
        guard message.frameInfo.isMainFrame,
              let frameURL = message.frameInfo.request.url,
              let source = Self.isHN(frameURL) ? frameURL : (frameURL.absoluteString == "about:blank" ? lazyURL : nil), Self.isHN(source),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "networkAcquire":
            guard let token = body["token"] as? Int, networkWaiters[token] == nil, !networkLeases.contains(token), networkWaiters.count + networkLeases.count < 4 else { return }
            let epoch = navigationID
            networkWaiters[token] = Task { [weak self] in
                await ReaderRequestPool.shared.acquire()
                guard let self, !Task.isCancelled, navigationID == epoch else { await ReaderRequestPool.shared.release(); return }
                networkWaiters[token] = nil
                networkLeases.insert(token)
                webView.callAsyncJavaScript("window.HackerViews?.networkGranted(token)", arguments: ["token": token], in: nil, in: Self.world) { [weak self] result in
                    if case .failure = result, let self, self.navigationID == epoch, self.networkLeases.remove(token) != nil { Task { await ReaderRequestPool.shared.release() } }
                }
            }
        case "networkRelease":
            if let token = body["token"] as? Int, networkLeases.remove(token) != nil { Task { await ReaderRequestPool.shared.release() } }
        case "performance":
            guard let event = body["event"] as? String, event.count < 64 else { return }
            var fields: [String: Any] = ["tab": id.uuidString, "navigation": navigationID.uuidString]
            for key in ["token", "id", "parent", "count", "ms", "queueMs", "bytes", "depth", "timeOrigin", "at", "reason", "groups", "visible", "version", "longTaskSupported", "layoutShiftSupported",
                        "frames", "frameTotal", "frameMax", "frameMin", "framesOver20", "framesOver34", "wheels", "scrollEvents",
                        "skipped", "unskipped", "heightChanges", "heightDelta", "heightMax", "longTasks", "longTaskMax",
                        "layoutShifts", "layoutShiftScore", "pumpCalls", "pumpTotal", "pumpMax", "renderCalls", "renderTotal",
                        "renderMax", "delta", "wheelAge", "scrolling", "anchorCalls", "anchorTotal", "anchorMax",
                        "anchorSelectTotal", "anchorRowsMax", "anchorChecked", "anchorCheckedMax", "anchorScrollCalls", "anchorWaitMax"] {
                if let value = body[key] as? NSNumber { fields[key] = value }
                else if key == "reason", let value = body[key] as? String, ["viewport", "navigation", "restore", "refresh"].contains(value) { fields[key] = value }
            }
            ReaderTrace.event("web." + event, fields)
        case "localRecheck":
            guard let ids = body["ids"] as? [Int], ids.count <= 20000,
                  ids.allSatisfy({ $0 > 0 }), let token = body["token"] as? Int else { return }
            let epoch = navigationID
            let policy = store.archive.policy
            Task { [weak self] in
                guard let self else { return }
                let result = await service.cachedDecisions(ids: ids, rules: policy.rules)
                guard navigationID == epoch, store.archive.policy == policy else { return }
                webView.callAsyncJavaScript("window.HackerViews?.localResult(token, effects, labels, inherited)",
                    arguments: ["token": token, "effects": result.effects, "labels": result.labels, "inherited": result.inherited],
                    in: nil, in: Self.world, completionHandler: nil)
            }
        case "lazyItems":
            guard lazyURL != nil, let ids = body["ids"] as? [Int], !ids.isEmpty, ids.count <= 8,
                  ids.allSatisfy({ $0 > 0 }), let token = body["token"] as? Int else { return }
            // JavaScript frees a slot when a result arrives, before the enclosing
            // native task necessarily finishes cleanup. Counting those tasks here
            // silently discarded valid replacement requests. The shared request
            // pool owns the network limit; accept and queue every valid batch.
            guard lazyTasks[token] == nil else { return }
            ReaderTrace.event("batch.start", ["tab": id.uuidString, "navigation": navigationID.uuidString, "token": token, "ids": ids])
            let epoch = navigationID
            let policy = store.archive.policy
            let priority = webView.window == nil ? 2 : (body["visible"] as? Bool == true ? 0 : 1)
            lazyTasks[token] = Task { [weak self] in
                guard let self else { return }
                defer { if navigationID == epoch { lazyTasks[token] = nil } }
                await withTaskGroup(of: (Int, HNService.ItemEffects).self) { group in
                    for itemID in ids {
                        group.addTask { await ReaderRequestPool.$priority.withValue(priority) { (itemID, await self.service.checkedContribution(itemID, rules: policy.rules)) } }
                    }
                    for await (itemID, decisions) in group {
                        guard !Task.isCancelled, navigationID == epoch, store.archive.policy == policy else { group.cancelAll(); return }
                        var entry: [String: Any] = ["id": itemID, "effect": decisions.effects[String(itemID)] ?? "unresolved", "label": decisions.labels[String(itemID)] ?? ""]
                        if let source = decisions.inherited[String(itemID)] { entry["inheritedFrom"] = source }
                        if decisions.effects[String(itemID)] == "unresolved" {
                            entry["reason"] = decisions.labels[String(itemID)] ?? "This contribution’s filter check could not finish."
                        } else if let item = try? await service.item(itemID), let data = try? JSONEncoder().encode(item), let object = try? JSONSerialization.jsonObject(with: data) {
                            entry["item"] = object
                            if item.type == "poll", let target = lazyURL, Self.topicID(target) == itemID {
                                // HN owns poll options, vote eligibility and submission.
                                canonicalTopicURL = target
                                lazyURL = nil
                                webView.load(URLRequest(url: target))
                                return
                            }
                            if item.type != "comment", lazyURL.flatMap(Self.topicID) == itemID {
                                threadTitle = item.title
                            }
                        } else { entry["effect"] = "unresolved"; entry["reason"] = "This contribution is no longer available from Hacker News." }
                        guard !Task.isCancelled, navigationID == epoch, store.archive.policy == policy else { group.cancelAll(); return }
                        ReaderTrace.event("comment.deliver", ["tab": self.id.uuidString, "navigation": epoch.uuidString, "token": token, "id": itemID])
                        webView.callAsyncJavaScript("window.HackerViews?.lazyResult(token, entries)", arguments: ["token": token, "entries": [entry]], in: nil, in: Self.world, completionHandler: nil)
                    }
                }
                ReaderTrace.event("batch.deliver", ["tab": self.id.uuidString, "navigation": epoch.uuidString, "token": token])
            }
        case "revealIntent":
            // Following a link out of a temporarily revealed contribution keeps
            // the destination revealed. The shell reads it when it loads; if the
            // intent lands after the shell, `ready` applies it.
            guard let id = body["id"] as? Int, id > 0 else { return }
            let owner = historyOwner ?? self
            owner.pendingReveal = (id, Date())
            let current = owner.activePage ?? owner
            if current.lazyURL.flatMap(Self.topicID) == id, current.state == .ready {
                current.webView.callAsyncJavaScript("window.HackerViews?.revealDestination()", arguments: [:], in: nil, in: Self.world, completionHandler: nil)
            }
        case "canonical":
            // The reader hands the discussion to HN's own page, such as when
            // HN's HTML offers no comment form the reader can host.
            guard let raw = body["url"] as? String, let target = URL(string: raw),
                  let topic = Self.topicID(target), topic == lazyURL.flatMap(Self.topicID) else { return }
            canonicalTopicURL = target
            lazyURL = nil
            webView.load(URLRequest(url: target))
        case "cancelLazy":
            lazyTasks.values.forEach { $0.cancel() }; lazyTasks.removeAll()
        case "collapsedState":
            if let ids = body["ids"] as? [Int] { saveCollapsedThreads(ids) }
        case "scrollPosition":
            guard state == .ready, restoreScrollY == nil,
                  let y = body["y"] as? Double, y.isFinite, y >= 0 else { return }
            saveReadingPosition(y: y, anchor: body["anchor"] as? [String: Any])
        case "pending": readinessID = UUID(); presenting = false; state = .loading; armTimeout()
        case "ready":
            destinationHidden = body["destinationHidden"] as? Bool ?? false
            timeout?.cancel()
            if let topic = lazyURL.flatMap(Self.topicID), consumePendingReveal(for: topic) {
                webView.callAsyncJavaScript("window.HackerViews?.revealDestination()", arguments: [:], in: nil, in: Self.world, completionHandler: nil)
            }
            if let y = restoreScrollY {
                if body["complete"] as? Bool == true {
                    restoreScrollY = nil
                    let epoch = navigationID
                    let anchor = refreshAnchor ?? [:]
                    refreshAnchor = nil
                    webView.callAsyncJavaScript("if (window.HackerViews) window.HackerViews.restoreReadingPosition(anchor, y); else window.scrollTo(0, y)",
                                                arguments: ["y": y, "anchor": anchor], in: nil, in: Self.world) { [weak self] _ in
                        guard let self, self.navigationID == epoch else { return }
                        self.presentReadyPage()
                    }
                }
            } else { presentReadyPage() }
            hiddenCount = body["hidden"] as? Int ?? 0
            unresolvedCount = body["unresolved"] as? Int ?? 0
            title = (body["title"] as? String ?? "Hacker News").replacingOccurrences(of: " | Hacker News", with: "")
            updateNavigation()
        case "held":
            blockingReason = body["label"] as? String ?? ""
            timeout?.cancel()
            state = body["reason"] as? String == "blocked" ? .blocked : .unresolved
        case "record":
            guard let username = body["username"] as? String, RecordArchive.validUsername(username) else { return }
            var citation: Citation?
            if let link = body["url"] as? String, RecordArchive.validCitationURL(link) {
                citation = Citation(url: link, author: username, excerpt: body["excerpt"] as? String ?? "",
                                    context: body["context"] as? String ?? "Hacker News")
            }
            onRecord?(RecordDraft(username: username, citation: citation, filtersOnly: source.path == "/user"))
        case "originalPoster":
            guard let id = body["id"] as? Int, id > 0, source.path == "/item",
                  URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value == String(id) else { return }
            let epoch = navigationID
            Task { [weak self] in
                guard let self else { return }
                var cursor: Int? = id
                var threadRootID: Int?
                var visited = Set<Int>()
                while let itemID = cursor, visited.count < 512, visited.insert(itemID).inserted {
                    guard let item = try? await service.item(itemID) else { return }
                    guard navigationID == epoch else { return }
                    if item.type != "comment" {
                        threadTitle = item.title
                        let author = item.by.flatMap { RecordArchive.validUsername($0) ? $0 : nil } ?? ""
                        webView.callAsyncJavaScript("window.HackerViews?.originalPoster(name, threadRootID)", arguments: ["name": author, "threadRootID": threadRootID ?? 0], in: nil, in: Self.world, completionHandler: nil)
                        return
                    }
                    threadRootID = item.id
                    cursor = item.parent
                }
            }
        case "profile":
            guard let name = body["username"] as? String, RecordArchive.validUsername(name),
                  let token = body["token"] as? Int, source.path == "/user",
                  URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value == name else { return }
            sendProfileRecord(name, archive: store.archive)
            let epoch = navigationID
            let policy = store.archive.policy
            Task { [weak self] in
                guard let self else { return }
                let match = await service.accountMatch(name, rules: policy.rules)
                guard navigationID == epoch, store.archive.policy == policy else { return }
                let result: [String: Any] = ["effect": match.effect, "label": match.label,
                    "ruleName": match.ruleName ?? "", "priority": match.priority ?? 0, "contributionCaveat": match.contributionCaveat]
                webView.callAsyncJavaScript("window.HackerViews?.resolveProfile(token, result)",
                    arguments: ["token": token, "result": result], in: nil, in: Self.world, completionHandler: nil)
            }
        case "profileSaveNote", "profileAddRef", "profileRemoveRef", "profileRefNote", "profileUpsertNote":
            guard source.path == "/user",
                  let name = URLComponents(url: source, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value,
                  RecordArchive.validUsername(name) else { return }
            let person = store.current(name)
            var note = person?.note ?? ""
            var references = person?.citations ?? []
            switch kind {
            case "profileSaveNote":
                guard let text = body["text"] as? String, text.utf8.count <= 100_000 else { return }
                note = text
            case "profileUpsertNote":
                guard let rawID = body["id"] as? String, let id = UUID(uuidString: rawID),
                      let url = body["url"] as? String, RecordArchive.validCitationURL(url),
                      let title = body["title"] as? String, title.utf8.count <= 10000,
                      let text = body["text"] as? String, text.utf8.count <= 100_000 else { return }
                if let index = references.firstIndex(where: { $0.id == id }) {
                    references[index].annotation = text; references[index].url = url; references[index].context = title
                } else {
                    var reference = Citation(url: url, author: name, excerpt: "", context: title)
                    reference.id = id; reference.annotation = text; reference.savedIntentionally = true
                    references.append(reference)
                }
            case "profileAddRef":
                guard let url = body["url"] as? String, RecordArchive.validCitationURL(url),
                      let title = body["title"] as? String, title.utf8.count <= 10000 else { return }
                var reference = Citation(url: url, author: name, excerpt: "", context: title)
                reference.savedIntentionally = true; references.append(reference)
            default:
                guard let id = body["id"] as? String, let index = references.firstIndex(where: { $0.id.uuidString == id }) else { return }
                if kind == "profileRemoveRef" { references.remove(at: index) }
                else {
                    guard let text = body["text"] as? String, text.utf8.count <= 100_000 else { return }
                    references[index].annotation = text
                }
            }
            let saved = store.save(username: name, blocked: person?.isBlocked ?? false, note: note, citations: references, preferred: person?.isPreferred)
            webView.callAsyncJavaScript("window.HackerViews?.profileSaveStatus(saved)", arguments: ["saved": saved], in: nil, in: Self.world, completionHandler: nil)
        case "highlights":
            guard let names = body["names"] as? [String], names.count <= 1000,
                  names.allSatisfy(RecordArchive.validUsername), let token = body["token"] as? Int else { return }
            let epoch = navigationID
            let policy = store.archive.policy
            Task { [weak self] in
                guard let self else { return }
                let matches = await service.highlights(names: names, filters: policy.highlights)
                guard navigationID == epoch, store.archive.policy == policy else { return }
                webView.callAsyncJavaScript("window.HackerViews?.resolveHighlights(token, names)",
                    arguments: ["token": token, "names": matches], in: nil, in: Self.world, completionHandler: nil)
            }
        case "ancestors":
            guard let ids = body["ids"] as? [Int], ids.allSatisfy({ $0 > 0 }),
                  let token = body["token"] as? Int else { return }
            guard ids.count <= 10000 else {
                timeout?.cancel()
                state = .failed("This page contains too many contributions to check at once. Open a smaller discussion branch.")
                return
            }
            let requestedIDs = Set(ids)
            var knownItems: [Int: HNItem] = [:]
            if let items = body["items"] as? [[String: Any]], items.count <= 10000 {
                for item in items {
                    guard let id = item["id"] as? Int, requestedIDs.contains(id),
                          let author = item["by"] as? String, RecordArchive.validUsername(author),
                          let type = item["type"] as? String, ["story", "comment"].contains(type) else { continue }
                    knownItems[id] = HNItem(id: id, by: author, parent: nil, type: type)
                }
            }
            let epoch = navigationID
            let policy = store.archive.policy
            Task { [weak self] in
                guard let self else { return }
                let decisions = await service.decisions(ids: ids, rules: policy.rules, knownItems: knownItems) { [weak self] partial in
                    await self?.showPartial(partial, token: token, epoch: epoch, policy: policy)
                }
                guard navigationID == epoch, store.archive.policy == policy else { return }
                webView.callAsyncJavaScript("window.HackerViews?.resolve(token, decisions, labels, inherited)",
                                            arguments: ["token": token, "decisions": decisions.effects, "labels": decisions.labels, "inherited": decisions.inherited],
                                            in: nil, in: Self.world, completionHandler: nil)
            }
        default: break
        }
    }

    private func sendProfileRecord(_ name: String, archive: RecordArchive) {
        let person = archive.current.first { $0.username == name }
        let references: [[String: Any]] = (person?.citations ?? []).map {
            ["id": $0.id.uuidString, "url": $0.url, "title": $0.context, "excerpt": $0.excerpt,
             "annotation": $0.annotation, "date": $0.capturedAt.formatted(date: .abbreviated, time: .omitted)]
        }
        webView.callAsyncJavaScript("window.HackerViews?.profileRecord(username, record)",
            arguments: ["username": name, "record": ["note": person?.note ?? "", "noteDate": person?.modifiedAt.formatted(date: .abbreviated, time: .omitted) ?? "", "references": references]],
            in: nil, in: Self.world, completionHandler: nil)
    }

    private func showPartial(_ result: HNService.ItemEffects, token: Int, epoch: UUID, policy: FilterPolicy) {
        guard navigationID == epoch, store.archive.policy == policy else { return }
        webView.callAsyncJavaScript("window.HackerViews?.resolvePartial(token, decisions, labels, inherited)",
            arguments: ["token": token, "decisions": result.effects, "labels": result.labels, "inherited": result.inherited],
            in: nil, in: Self.world, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        cancelNetworkLeases()
        destinationHidden = false; revealedDestination = false; blockingReason = ""
        presenting = false
        lazyTasks.values.forEach { $0.cancel() }; lazyTasks.removeAll()
        navigationID = UUID(); state = .loading; hiddenCount = 0; armTimeout(); updateNavigation()
    }
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        if let target = webView.url { recordNavigation(target) }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { pendingFormSubmission = false; updateNavigation() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        pendingFormSubmission = false
        state = .failed("The browser process stopped. Reload to continue.")
    }
    private func fail(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        pendingFormSubmission = false
        timeout?.cancel(); state = .failed(error.localizedDescription)
    }
    private func updateNavigation() {
        updateHistoryButtons()
        onSessionChange?()
    }

    func preservesCanonicalNavigation(to target: URL, type: WKNavigationType, isMainFrame: Bool) -> Bool {
        guard isMainFrame, Self.isHN(target) else { return false }
        if target == canonicalTopicURL {
            canonicalTopicURL = nil
            pendingFormSubmission = false
            return true
        }
        switch type {
        case .formSubmitted, .formResubmitted:
            if pendingFormSubmission, Self.topicID(target) != nil {
                pendingFormSubmission = false
                lazyURL = nil
                return true
            }
            pendingFormSubmission = true
            return false
        case .other:
            let keep = pendingFormSubmission && Self.topicID(target) != nil
            pendingFormSubmission = false
            if keep { lazyURL = nil }
            return keep
        default:
            pendingFormSubmission = false
            return false
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else { decisionHandler(.cancel); return }
        if shellNavigation && (target.absoluteString == "about:blank" || target == lazyURL) {
            shellNavigation = false
            decisionHandler(.allow)
            return
        }
        if Self.isHN(target) {
            if preservesCanonicalNavigation(to: target, type: navigationAction.navigationType,
                                            isMainFrame: navigationAction.targetFrame?.isMainFrame == true) {
                decisionHandler(.allow)
                return
            }
            #if os(macOS)
            if navigationAction.navigationType == .linkActivated,
               navigationAction.modifierFlags.contains(.command) {
                onOpenTab?(target, navigationAction.modifierFlags.contains(.shift))
                decisionHandler(.cancel)
                return
            }
            #endif
            if let historyOwner, navigationAction.targetFrame?.isMainFrame == true,
               navigationAction.navigationType == .linkActivated {
                var destination = URLComponents(url: target, resolvingAgainstBaseURL: false)
                var current = url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }
                destination?.fragment = nil; current?.fragment = nil
                if destination?.url == current?.url, target.fragment != nil {
                    decisionHandler(.allow)
                    return
                }
                if destination?.url != current?.url {
                    decisionHandler(.cancel)
                    historyOwner.load(target)
                    return
                }
            }
            if navigationAction.navigationType == .backForward,
               let index = history.indices.first(where: { $0 != historyIndex && history[$0].url == target }) {
                if history.indices.contains(historyIndex) { history[historyIndex].scrollY = scrollY }
                historyIndex = index
                scrollY = history[index].scrollY
                restoreScrollY = scrollY
                refreshAnchor = history[index].restorationAnchor
                url = target
                updateHistoryButtons()
            }
            if navigationAction.targetFrame == nil {
                onOpenTab?(target, true); decisionHandler(.cancel)
            } else if navigationAction.targetFrame?.isMainFrame == true, Self.topicID(target) != nil,
                      navigationAction.navigationType != .formSubmitted {
                decisionHandler(.cancel)
                recordNavigation(target)
                loadTopic(target)
            } else if navigationAction.targetFrame?.isMainFrame == true,
                      state == .ready, webView.bounds.width > 0, webView.bounds.height > 0 {
                // Canonical form/redirect navigation may replace this page.
                // Capture its contribution offset before allowing that transition.
                let capture = UUID()
                captureID = capture
                webView.callAsyncJavaScript("return window.HackerViews?.readingPosition() ?? {y: window.scrollY}",
                                           arguments: [:], in: nil, in: Self.world) { [weak self] result in
                    guard let self, self.captureID == capture else { decisionHandler(.cancel); return }
                    if case .success(let value) = result, let anchor = value as? [String: Any],
                       let y = anchor["y"] as? Double, y.isFinite, y >= 0,
                       self.history.indices.contains(self.historyIndex) {
                        self.scrollY = y
                        self.history[self.historyIndex].scrollY = y
                        self.history[self.historyIndex].anchor = try? JSONSerialization.data(withJSONObject: anchor)
                    }
                    webView.takeSnapshot(with: nil) { [weak self] image, _ in
                    guard let self, self.captureID == capture else { decisionHandler(.cancel); return }
                    if self.state == .ready { self.navigationSnapshot = image }
                    self.state = .loading
                    self.lazyURL = nil
                    decisionHandler(.allow)
                    }
                }
            } else { lazyURL = nil; decisionHandler(.allow) }
        } else {
            // External articles go to the user's browser. No app bridge is exposed there.
            if navigationAction.navigationType == .linkActivated && ["https", "http", "mailto"].contains(target.scheme ?? "") {
                #if os(macOS)
                ExternalBrowser.open(target)
                #else
                UIApplication.shared.open(target)
                #endif
            }
            decisionHandler(.cancel)
        }
    }
}

@MainActor
private final class WeakMessageHandler: NSObject, WKScriptMessageHandler {
    weak var owner: BrowserTab?
    init(_ owner: BrowserTab) { self.owner = owner }
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) { owner?.receive(message) }
}

#if os(macOS)
struct WebSurface: NSViewRepresentable {
    let tab: BrowserTab
    func makeNSView(context: Context) -> WKWebView { tab.restoreRetainedViewport(); return tab.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
struct WebSurface: UIViewRepresentable {
    let tab: BrowserTab
    func makeUIView(context: Context) -> WKWebView { tab.restoreRetainedViewport(); return tab.webView }
    func updateUIView(_ view: WKWebView, context: Context) {}
}
#endif

#if os(macOS)
@MainActor
enum ExternalBrowser {
    static func privateArguments(bundleID: String, url: URL) -> [String]? {
        guard ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        switch bundleID {
        case "org.mozilla.firefox", "org.mozilla.firefoxdeveloperedition", "org.mozilla.nightly":
            return ["-private-window", url.absoluteString]
        case "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
             "org.chromium.Chromium", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly":
            return ["--incognito", url.absoluteString]
        case "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary":
            return ["--inprivate", url.absoluteString]
        default: return nil
        }
    }
    static func open(_ url: URL) {
        guard UserDefaults.standard.bool(forKey: "HackerViews.preferPrivateExternalLinks"),
              let appURL = NSWorkspace.shared.urlForApplication(toOpen: url),
              let bundle = Bundle(url: appURL), let id = bundle.bundleIdentifier,
              let arguments = privateArguments(bundleID: id, url: url),
              let executable = bundle.executableURL else {
            NSWorkspace.shared.open(url)
            return
        }
        // Invoke the browser directly: Launch Services may ignore launch arguments
        // when an app is already running. Arguments are never interpreted by a shell.
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let started = ProcessInfo.processInfo.systemUptime
        process.terminationHandler = { process in
            // A browser may remain running for hours; a later crash must not reopen
            // an old link. Only an immediate rejected launch triggers fallback.
            guard process.terminationStatus != 0,
                  ProcessInfo.processInfo.systemUptime - started < 10 else { return }
            Task { @MainActor in NSWorkspace.shared.open(url) }
        }
        do { try process.run() }
        catch { NSWorkspace.shared.open(url) }
    }
}
#endif
