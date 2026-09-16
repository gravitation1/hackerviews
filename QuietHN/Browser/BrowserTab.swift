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

enum PageState: Equatable {
    case loading, ready, blocked, unresolved, failed(String)
}

@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate {
    let id = UUID()
    @Published var title = "Hacker News"
    @Published var url: URL?
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var state: PageState = .loading
    @Published var hiddenCount = 0
    @Published var unresolvedCount = 0
    var onRecord: ((RecordDraft) -> Void)?
    var onOpenTab: ((URL) -> Void)?
    private let store: RecordStore
    private let service: HNService
    private let persistentSession: Bool
    private var subscription: AnyCancellable?
    private var recordSubscription: AnyCancellable?
    private var navigationID = UUID()
    private var timeout: Task<Void, Never>?
    private static let world = WKContentWorld.world(name: "QuietHN")

    lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = persistentSession ? .default() : .nonPersistent()
        configuration.userContentController.add(WeakMessageHandler(self), contentWorld: Self.world, name: "quietHN")
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        view.uiDelegate = self
        view.allowsBackForwardNavigationGestures = true
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
            self.state = .loading
            self.armTimeout()
            self.webView.callAsyncJavaScript("window.QuietHN?.setOrdered(active)", arguments: ["active": policy.rules.contains { $0.isActive }],
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
        state = .loading
        webView.load(URLRequest(url: url))
    }
    func back() { webView.goBack() }
    func forward() { webView.goForward() }
    func reload() { state = .loading; webView.reload() }
    func retry() {
        state = .loading; armTimeout()
        webView.callAsyncJavaScript("window.QuietHN?.retry()", arguments: [:], in: nil, in: Self.world, completionHandler: nil)
    }

    static func isHN(_ url: URL) -> Bool {
        url.scheme == "https" && url.host == "news.ycombinator.com" && url.user == nil && url.password == nil && (url.port == nil || url.port == 443)
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
        controller.addUserScript(WKUserScript(source: "window.__quietHNOrdered = true; window.__quietHNOrderedActive = \(policy.rules.contains { $0.isActive }); window.__quietHNBlocked = \(names); window.__quietHNAccountFiltersActive = \(policy.accounts.isActive); window.__quietHNPreferred = \(preferred); window.__quietHNHighlightActive = \(policy.highlights.isActive);\n" + script,
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
              let source = message.frameInfo.request.url, Self.isHN(source),
              let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        switch kind {
        case "pending": state = .loading; armTimeout()
        case "ready":
            timeout?.cancel(); state = .ready
            hiddenCount = body["hidden"] as? Int ?? 0
            unresolvedCount = body["unresolved"] as? Int ?? 0
            title = (body["title"] as? String ?? "Hacker News").replacingOccurrences(of: " | Hacker News", with: "")
            updateNavigation()
        case "held":
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
                webView.callAsyncJavaScript("window.QuietHN?.resolveProfile(token, result)",
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
            webView.callAsyncJavaScript("window.QuietHN?.profileSaveStatus(saved)", arguments: ["saved": saved], in: nil, in: Self.world, completionHandler: nil)
        case "highlights":
            guard let names = body["names"] as? [String], names.count <= 1000,
                  names.allSatisfy(RecordArchive.validUsername), let token = body["token"] as? Int else { return }
            let epoch = navigationID
            let policy = store.archive.policy
            Task { [weak self] in
                guard let self else { return }
                let matches = await service.highlights(names: names, filters: policy.highlights)
                guard navigationID == epoch, store.archive.policy == policy else { return }
                webView.callAsyncJavaScript("window.QuietHN?.resolveHighlights(token, names)",
                    arguments: ["token": token, "names": matches], in: nil, in: Self.world, completionHandler: nil)
            }
        case "ancestors":
            guard let ids = body["ids"] as? [Int], ids.count <= 1000, ids.allSatisfy({ $0 > 0 }),
                  let token = body["token"] as? Int else { return }
            let epoch = navigationID
            let policy = store.archive.policy
            Task { [weak self] in
                guard let self else { return }
                let decisions = await service.decisions(ids: ids, rules: policy.rules) { [weak self] partial in
                    await self?.showPartial(partial, token: token, epoch: epoch, policy: policy)
                }
                guard navigationID == epoch, store.archive.policy == policy else { return }
                webView.callAsyncJavaScript("window.QuietHN?.resolve(token, decisions, labels)",
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
        webView.callAsyncJavaScript("window.QuietHN?.profileRecord(username, record)",
            arguments: ["username": name, "record": ["note": person?.note ?? "", "noteDate": person?.modifiedAt.formatted(date: .abbreviated, time: .omitted) ?? "", "references": references]],
            in: nil, in: Self.world, completionHandler: nil)
    }

    private func showPartial(_ result: HNService.ItemEffects, token: Int, epoch: UUID, policy: FilterPolicy) {
        guard navigationID == epoch, store.archive.policy == policy else { return }
        webView.callAsyncJavaScript("window.QuietHN?.resolvePartial(token, decisions, labels)",
            arguments: ["token": token, "decisions": result.effects, "labels": result.labels],
            in: nil, in: Self.world, completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        navigationID = UUID(); state = .loading; hiddenCount = 0; armTimeout(); updateNavigation()
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
        canGoBack = webView.canGoBack; canGoForward = webView.canGoForward; url = webView.url
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping @MainActor @Sendable (WKNavigationActionPolicy) -> Void) {
        guard let target = navigationAction.request.url else { decisionHandler(.cancel); return }
        if Self.isHN(target) {
            if navigationAction.targetFrame == nil {
                onOpenTab?(target); decisionHandler(.cancel)
            } else { decisionHandler(.allow) }
        } else {
            // External articles go to the user's browser. No app bridge is exposed there.
            if navigationAction.navigationType == .linkActivated && ["https", "http", "mailto"].contains(target.scheme ?? "") {
                #if os(macOS)
                NSWorkspace.shared.open(target)
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
