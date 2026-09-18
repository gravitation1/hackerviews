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
    @Published var title = "Hacker News"
    @Published var threadTitle: String?
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var state: PageState = .loading
    @Published private(set) var navigationSnapshot: NavigationImage?
    private var lazyURL: URL?
    private var shellNavigation = false
    private var networkWaiters: [Int: Task<Void, Never>] = [:]
    private var networkLeases = Set<Int>()
    private var lazyTasks: [Int: Task<Void, Never>] = [:]
    private var captureID = UUID()
    private var presenting = false
    private var readinessID = UUID()
    @Published var destinationHidden = false
    @Published var revealedDestination = false
    @Published var blockingReason = ""
    var savedReferences: [Citation] {
        guard let url = webView.url ?? url else { return [] }
        return store.people.flatMap(\.citations).filter { $0.url == url.absoluteString }
    }
    func revealDestination() {
        revealedDestination = true
        webView.callAsyncJavaScript("window.HackerViews?.revealDestination()", arguments: [:], in: nil, in: Self.world, completionHandler: nil)
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
    }
    private(set) var history: [HistoryEntry] = []
    private(set) var historyIndex = -1
    var scrollY: Double = 0
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

    lazy var webView: WKWebView = {
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

    init(store: RecordStore, service: HNService, persistentSession: Bool = true) {
        self.store = store; self.service = service; self.persistentSession = persistentSession
        super.init()
        subscription = store.$archive.map(\.policy).removeDuplicates().dropFirst().sink { [weak self] policy in
            guard let self else { return }
            self.installScripts(in: self.webView, policy: policy)
            self.webView.callAsyncJavaScript("window.HackerViews?.setOrdered(active, true)",
                arguments: ["active": policy.rules.contains { $0.isActive }],
                in: nil, in: Self.world, completionHandler: nil)
        }
        recordSubscription = store.$archive.dropFirst().sink { [weak self] archive in
            guard let self, let url = self.webView.url, url.path == "/user",
                  let name = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first(where: { $0.name == "id" })?.value else { return }
            self.sendProfileRecord(name, archive: archive)
        }

    }

    func load(_ url: URL) {
        guard Self.isHN(url) else { return }
        recordNavigation(url)
        if Self.topicID(url) != nil { loadTopic(url) }
        else { lazyURL = nil; webView.load(URLRequest(url: url)) }
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
        webView.loadHTMLString("""
        <!doctype html><html><head><meta name="viewport" content="width=device-width, initial-scale=1"><title>Hacker News</title></head>
        <body data-hv-topic="\(id)" data-hv-scroll="\(y)" data-hv-anchor="\(anchorData)"><main id="hv-topic">
        <nav class="hv-topic-nav"><a href="https://news.ycombinator.com/">home</a> · <a href="https://news.ycombinator.com/newest">new</a> · <a href="https://news.ycombinator.com/ask">ask</a> · <a href="https://news.ycombinator.com/show">show</a> · <a href="https://news.ycombinator.com/threads">threads</a> · <a href="https://news.ycombinator.com/submit">submit</a> · <a href="https://news.ycombinator.com/login">login</a></nav>
        <div id="hv-topic-root"></div></main></body></html>
        """, baseURL: target)
    }
    func restoreHistory(_ entries: [HistoryEntry], index: Int) {
        guard !entries.isEmpty, entries.indices.contains(index),
              entries.allSatisfy({ Self.isHN($0.url) && $0.scrollY.isFinite && $0.scrollY >= 0 }) else { return }
        history = entries
        historyIndex = index
        refreshAnchor = entries[index].anchor.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
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
    var savedHistory: [HistoryEntry] {
        var entries = history
        if entries.indices.contains(historyIndex) { entries[historyIndex].scrollY = scrollY }
        return entries
    }
    private func updateHistoryButtons() {
        canGoBack = historyIndex > 0
        canGoForward = historyIndex >= 0 && historyIndex + 1 < history.count
    }
    func back() { travel(to: historyIndex - 1) }
    func forward() { travel(to: historyIndex + 1) }
    private func travel(to index: Int) {
        guard history.indices.contains(index) else { return }
        if history.indices.contains(historyIndex) { history[historyIndex].scrollY = scrollY }
        historyIndex = index
        scrollY = history[index].scrollY
        restoreScrollY = scrollY
        refreshAnchor = history[index].anchor.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        url = history[index].url
        updateHistoryButtons()
        onSessionChange?()
        if Self.topicID(history[index].url) != nil { loadTopic(history[index].url) }
        else { lazyURL = nil; webView.load(URLRequest(url: history[index].url)) }
    }
    func scrollToTop() {
        restoreScrollY = nil
        refreshAnchor = nil
        webView.callAsyncJavaScript("window.scrollTo({top: 0, left: 0, behavior: 'instant'})",
                                   arguments: [:], in: nil, in: Self.world, completionHandler: nil)
    }
    func reload() {
        let epoch = navigationID
        webView.callAsyncJavaScript("return window.HackerViews?.readingPosition() ?? {y: window.scrollY}",
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
                webView.callAsyncJavaScript("window.HackerViews?.localResult(token, effects, labels)",
                    arguments: ["token": token, "effects": result.effects, "labels": result.labels],
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
                        if decisions.effects[String(itemID)] == "unresolved" {
                            entry["reason"] = decisions.labels[String(itemID)] ?? "This contribution’s filter check could not finish."
                        } else if let item = try? await service.item(itemID), let data = try? JSONEncoder().encode(item), let object = try? JSONSerialization.jsonObject(with: data) {
                            entry["item"] = object
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
        case "cancelLazy":
            lazyTasks.values.forEach { $0.cancel() }; lazyTasks.removeAll()
        case "scrollPosition":
            guard state == .ready, restoreScrollY == nil,
                  let y = body["y"] as? Double, y.isFinite, y >= 0 else { return }
            saveReadingPosition(y: y, anchor: body["anchor"] as? [String: Any])
        case "pending": readinessID = UUID(); presenting = false; state = .loading; armTimeout()
        case "ready":
            destinationHidden = body["destinationHidden"] as? Bool ?? false
            timeout?.cancel()
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
                    "ruleName": match.ruleName ?? "", "priority": match.priority ?? 0]
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
                webView.callAsyncJavaScript("window.HackerViews?.resolve(token, decisions, labels)",
                                            arguments: ["token": token, "decisions": decisions.effects, "labels": decisions.labels],
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
        webView.callAsyncJavaScript("window.HackerViews?.resolvePartial(token, decisions, labels)",
            arguments: ["token": token, "decisions": result.effects, "labels": result.labels],
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
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { updateNavigation() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { fail(error) }
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        state = .failed("The browser process stopped. Reload to continue.")
    }
    private func fail(_ error: Error) {
        if (error as NSError).code == NSURLErrorCancelled { return }
        timeout?.cancel(); state = .failed(error.localizedDescription)
    }
    private func updateNavigation() {
        updateHistoryButtons()
        onSessionChange?()
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
            #if os(macOS)
            if navigationAction.navigationType == .linkActivated,
               navigationAction.modifierFlags.contains(.command) {
                onOpenTab?(target, navigationAction.modifierFlags.contains(.shift))
                decisionHandler(.cancel)
                return
            }
            #endif
            if navigationAction.navigationType == .backForward,
               let index = history.indices.first(where: { $0 != historyIndex && history[$0].url == target }) {
                if history.indices.contains(historyIndex) { history[historyIndex].scrollY = scrollY }
                historyIndex = index
                scrollY = history[index].scrollY
                restoreScrollY = scrollY
                refreshAnchor = history[index].anchor.flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
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
                // Our topic shell is rebuilt on Back: retain the contribution and
                // its viewport offset, not just a pixel offset into a partial tree.
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
    func makeNSView(context: Context) -> WKWebView { tab.webView }
    func updateNSView(_ view: WKWebView, context: Context) {}
}
#else
struct WebSurface: UIViewRepresentable {
    let tab: BrowserTab
    func makeUIView(context: Context) -> WKWebView { tab.webView }
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
