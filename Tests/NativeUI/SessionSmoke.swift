import SwiftUI
import AppKit
import WebKit

@main struct SessionSmoke {
    @MainActor static func main() {
        let external = URL(string: "https://example.com/?q=a%20b&literal=%24(test)")!
        precondition(ExternalBrowser.privateArguments(bundleID: "org.mozilla.firefox", url: external) == ["-private-window", external.absoluteString])
        precondition(ExternalBrowser.privateArguments(bundleID: "com.google.Chrome", url: external) == ["--incognito", external.absoluteString])
        precondition(ExternalBrowser.privateArguments(bundleID: "com.microsoft.edgemac", url: external) == ["--inprivate", external.absoluteString])
        precondition(ExternalBrowser.privateArguments(bundleID: "com.apple.Safari", url: external) == nil)
        precondition(ExternalBrowser.privateArguments(bundleID: "org.mozilla.firefox", url: URL(string: "mailto:reader@example.com")!) == nil)
        print("PASS private browser routing and unsupported-browser fallback selection")
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "HackerViews.SessionTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = RecordStore(directory: directory)
        let navigation = BrowserTab(store: store, service: HNService.shared, persistentSession: false)
        let commentURL = URL(string: "https://news.ycombinator.com/comment")!
        let topicURL = URL(string: "https://news.ycombinator.com/item?id=123#456")!
        precondition(!navigation.preservesCanonicalNavigation(to: commentURL, type: .formSubmitted, isMainFrame: true))
        precondition(navigation.preservesCanonicalNavigation(to: topicURL, type: .other, isMainFrame: true), "Reply redirect must retain fresh HN HTML")
        precondition(!navigation.preservesCanonicalNavigation(to: topicURL, type: .linkActivated, isMainFrame: true), "Later topic visits resume normal routing")
        _ = navigation.preservesCanonicalNavigation(to: commentURL, type: .formSubmitted, isMainFrame: true)
        _ = navigation.preservesCanonicalNavigation(to: URL(string: "https://news.ycombinator.com/newest")!, type: .linkActivated, isMainFrame: true)
        precondition(!navigation.preservesCanonicalNavigation(to: topicURL, type: .other, isMainFrame: true), "Leaving an unsuccessful form clears submission routing")
        for path in ["edit", "delete", "delete-confirm", "xedit", "xdelete", "x?fnid=fixture", "submit"] {
            _ = navigation.preservesCanonicalNavigation(to: URL(string: "https://news.ycombinator.com/" + path)!, type: .formSubmitted, isMainFrame: true)
            precondition(navigation.preservesCanonicalNavigation(to: topicURL, type: .other, isMainFrame: true))
        }
        for (post, redirect) in [("login", "news"), ("r", "newest")] {
            _ = navigation.preservesCanonicalNavigation(to: URL(string: "https://news.ycombinator.com/" + post)!, type: .formSubmitted, isMainFrame: true)
            precondition(!navigation.preservesCanonicalNavigation(to: URL(string: "https://news.ycombinator.com/" + redirect)!, type: .other, isMainFrame: true))
            precondition(!navigation.preservesCanonicalNavigation(to: topicURL, type: .linkActivated, isMainFrame: true))
        }
        _ = navigation.preservesCanonicalNavigation(to: commentURL, type: .formSubmitted, isMainFrame: true)
        precondition(navigation.preservesCanonicalNavigation(to: topicURL, type: .formSubmitted, isMainFrame: true))
        precondition(!navigation.preservesCanonicalNavigation(to: topicURL, type: .linkActivated, isMainFrame: true))
        _ = navigation.preservesCanonicalNavigation(to: commentURL, type: .formResubmitted, isMainFrame: true)
        precondition(navigation.preservesCanonicalNavigation(to: topicURL, type: .other, isMainFrame: true))
        precondition(!navigation.preservesCanonicalNavigation(to: topicURL, type: .linkActivated, isMainFrame: true))
        for action in [WKNavigationType.linkActivated, .reload, .backForward] {
            _ = navigation.preservesCanonicalNavigation(to: commentURL, type: .formSubmitted, isMainFrame: true)
            precondition(!navigation.preservesCanonicalNavigation(to: topicURL, type: action, isMainFrame: true))
            precondition(!navigation.preservesCanonicalNavigation(to: topicURL, type: .other, isMainFrame: true))
        }
        _ = navigation.preservesCanonicalNavigation(to: commentURL, type: .formSubmitted, isMainFrame: true)
        navigation.webView(navigation.webView, didFailProvisionalNavigation: nil, withError: URLError(.timedOut))
        precondition(!navigation.preservesCanonicalNavigation(to: topicURL, type: .other, isMainFrame: true))
        _ = navigation.preservesCanonicalNavigation(to: commentURL, type: .formSubmitted, isMainFrame: true)
        navigation.webView(navigation.webView, didFinish: nil)
        precondition(!navigation.preservesCanonicalNavigation(to: topicURL, type: .other, isMainFrame: true))
        print("PASS submission state consumed by redirects, clicks, reload/back, completion and failure")
        print("PASS edit/delete submission redirects preserve fresh canonical content")
        print("PASS reply submission redirects preserve canonical content only for that navigation")
        let first = BrowserWorkspace(store: store, defaults: defaults)
        first.start()
        let home = first.tabs[0]
        home.scrollY = 820
        first.open(URL(string: "https://news.ycombinator.com/item?id=123")!)
        first.tabs[1].saveReadingPosition(y: 2400, anchor: ["id": 124, "y": 2400, "top": -30.0, "ancestors": [123]])
        first.tabs[1].title = "Saved discussion"
        first.tabs[1].recordNavigation(URL(string: "https://news.ycombinator.com/item?id=456")!)
        first.tabs[1].scrollY = 600
        first.tabs[1].recordNavigation(URL(string: "https://news.ycombinator.com/item?id=789")!)
        first.tabs[1].back()
        precondition(first.tabs[1].canGoBack && first.tabs[1].canGoForward)
        first.selectedID = home.id
        first.saveSession()
        let restored = BrowserWorkspace(store: store, defaults: defaults)
        restored.start()
        precondition(restored.tabs.count == 2)
        precondition(restored.selectedID == restored.tabs[0].id)
        precondition(restored.tabs[0].displayedPage.restoreScrollY == 820)
        precondition(restored.tabs[1].scrollY == 600)
        precondition(restored.tabs[1].title == "Saved discussion")
        precondition(restored.tabs[1].url?.query == "id=456")
        precondition(restored.tabs[1].canGoBack && restored.tabs[1].canGoForward)
        precondition(restored.tabs[0].pendingRestoredURL == nil)
        precondition(restored.tabs[1].pendingRestoredURL?.query == "id=456")
        precondition(!restored.tabs[1].hasCreatedWebView, "Background restoration must not instantiate a web view")
        var changedRules = store.archive.rules
        changedRules[0].assignedUsers.insert("fixture")
        precondition(store.save(username: "fixture", blocked: false, note: "Publication", citations: [], rules: changedRules))
        precondition(!restored.tabs[1].hasCreatedWebView, "Archive and policy publications must preserve deferred web views")
        restored.saveSession()
        restored.selectedID = restored.tabs[1].id
        precondition(restored.tabs[1].pendingRestoredURL == nil, "Selecting a restored tab starts its deferred load once")
        precondition(restored.tabs[1].scrollY == 600 && restored.tabs[1].canGoForward)
        print("PASS restored background tabs defer loading while retaining URL, history and position")
        restored.tabs[1].back()
        precondition(restored.tabs[1].url?.query == "id=123")
        precondition(restored.tabs[1].scrollY == 2400)
        let savedAnchor = try! JSONSerialization.jsonObject(with: restored.tabs[1].savedHistory[0].anchor!) as! [String: Any]
        precondition(savedAnchor["id"] as? Int == 124 && savedAnchor["top"] as? Double == -30,
                     "Back must retain the comment anchor across session persistence")
        restored.tabs[1].forward()
        precondition(restored.tabs[1].url?.query == "id=456")
        restored.tabs[1].restoreScrollY = nil
        restored.tabs[1].recordNavigation(URL(string: "https://news.ycombinator.com/item?id=999")!)
        precondition(!restored.tabs[1].canGoForward)
        precondition(restored.tabs[1].history.count == 3)
        precondition(!restored.tabs[1].revealedDestination, "Temporary reveals must not survive relaunch")
        restored.close(restored.tabs[1])
        let afterClose = BrowserWorkspace(store: store, defaults: defaults)
        afterClose.start()
        precondition(afterClose.tabs.count == 1)
        defaults.set(Data("invalid".utf8), forKey: "HackerViews.readerSession")
        let recovery = BrowserWorkspace(store: store, defaults: defaults)
        recovery.start()
        precondition(recovery.tabs.count == 1)
        precondition(recovery.tabs[0].url?.absoluteString == "https://news.ycombinator.com/")
        let active = recovery.selectedID
        recovery.open(URL(string: "https://news.ycombinator.com/user?id=alice")!, select: false)
        precondition(recovery.tabs.count == 2)
        precondition(recovery.selectedID == active, "Background links must preserve the active tab")
        recovery.open(URL(string: "https://news.ycombinator.com/user?id=bob")!, select: true)
        precondition(recovery.selectedID == recovery.tabs.last?.id)
        let neighbor = recovery.tabs[1].id
        precondition(recovery.closeSelectedTab())
        precondition(recovery.tabs.count == 2 && recovery.selectedID == neighbor)
        precondition(recovery.closeSelectedTab())
        let lastID = recovery.selectedID
        precondition(!recovery.closeSelectedTab())
        precondition(recovery.tabs.count == 1 && recovery.selectedID == lastID)
        print("PASS close-tab command selects its neighbor and preserves the last tab for window restoration")
        print("PASS foreground/background tab selection")
        print("PASS session: restored back/forward history and per-entry scroll, branching, tabs, invalid-data recovery; no persisted reveal")
    }
}
