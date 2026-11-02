import SwiftUI
import AppKit
import WebKit

actor Fetches {
    var counts: [Int: Int] = [:]
    func add(_ id: Int) { counts[id, default: 0] += 1 }
}

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
        _ = navigation.preservesCanonicalNavigation(to: commentURL, type: .formSubmitted, isMainFrame: true)
        precondition(navigation.preservesCanonicalNavigation(to: topicURL, type: .other, isMainFrame: true) && navigation.commentLanding, "a posted comment lands in the reader")
        precondition(!navigation.preservesCanonicalNavigation(to: topicURL, type: .linkActivated, isMainFrame: true) && !navigation.commentLanding)
        for path in ["xedit", "xdelete"] {
            _ = navigation.preservesCanonicalNavigation(to: URL(string: "https://news.ycombinator.com/" + path)!, type: .formSubmitted, isMainFrame: true)
            precondition(navigation.preservesCanonicalNavigation(to: topicURL, type: .other, isMainFrame: true) && !navigation.commentLanding, "an edit or deletion keeps HN's page")
        }
        print("PASS a posted comment lands in the reader; edits and deletions keep HN's page")
        let fetches = Fetches()
        let replies = HNService(directory: directory.appendingPathComponent("replies"), itemLoader: { id in
            await fetches.add(id)
            return HNItem(id: id, by: "author", parent: id == 123 ? nil : 123, type: id == 123 ? "story" : "comment", kids: [])
        })
        let posting = BrowserTab(store: store, service: replies, persistentSession: false)
        var expired = false
        Task { @MainActor in
            for id in [123, 456, 789] { _ = try! await replies.item(id) }
            _ = posting.preservesCanonicalNavigation(to: commentURL, type: .formSubmitted, isMainFrame: true)
            precondition(posting.preservesCanonicalNavigation(to: topicURL, type: .other, isMainFrame: true))
            try? await Task.sleep(for: .milliseconds(50))
            for id in [123, 456, 789] { _ = try! await replies.item(id) }
            let counts = await fetches.counts
            precondition(counts[123] == 2 && counts[456] == 2, "the discussion and the comment a post lands on are fetched again, got \(counts)")
            precondition(counts[789] == 1, "other items keep their cached copies, got \(counts)")
            expired = true
        }
        while !expired { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        print("PASS a post's landing discussion and comment are fetched fresh, so the reader shows the reply")
        let deep = HNService(directory: directory.appendingPathComponent("deep"), itemLoader: { id in
            HNItem(id: id, by: "author", parent: id == 1 ? nil : id - 1, type: id == 1 ? "story" : "comment", kids: [])
        })
        var traced = false
        Task { @MainActor in
            let path = await BrowserTab.ancestry(of: 5, in: 1, service: deep)
            precondition(path == [1, 2, 3, 4], "the path to a replied comment runs root first, got \(String(describing: path))")
            let elsewhere = await BrowserTab.ancestry(of: 5, in: 99, service: deep)
            precondition(elsewhere == nil, "a comment outside the discussion has no path in it")
            traced = true
        }
        while !traced { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        print("PASS a posted reply's landing knows the path to the comment it answered")
        let first = BrowserWorkspace(store: store, defaults: defaults)
        first.start()
        let home = first.tabs[0]
        home.scrollY = 820
        first.open(URL(string: "https://news.ycombinator.com/item?id=123")!)
        first.tabs[1].saveReadingPosition(y: 2400, anchor: ["id": 124, "y": 2400, "top": -30.0, "ancestors": [123]])
        first.tabs[1].saveCollapsedThreads([124, 125])
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
        precondition(restored.tabs[1].savedHistory[0].collapsed == [124,125], "Collapsed threads must survive session serialization and deferred history loading")
        precondition(restored.tabs[1].displayedPage.savedHistory.last?.collapsed == [124,125])
        restored.tabs[1].saveCollapsedThreads([125])
        restored.saveSession()
        let expandedRestore = BrowserWorkspace(store: store, defaults: defaults)
        expandedRestore.start()
        precondition(expandedRestore.tabs[1].savedHistory[0].collapsed == [125], "Expansion must persist without a scroll event")
        restored.tabs[1].forward()
        precondition(restored.tabs[1].url?.query == "id=456")
        restored.tabs[1].restoreScrollY = nil
        restored.tabs[1].recordNavigation(URL(string: "https://news.ycombinator.com/item?id=999")!)
        precondition(!restored.tabs[1].canGoForward)
        precondition(restored.tabs[1].history.count == 3)
        precondition(!restored.tabs[1].revealedDestination, "Temporary reveals must not survive relaunch")
        restored.tabs[1].scrollY = 300
        restored.duplicate(restored.tabs[1])
        let copy = restored.tabs[2], source = restored.tabs[1]
        precondition(restored.selectedID == copy.id, "A duplicate is selected")
        precondition(copy.url == source.url && copy.title == source.title && copy.scrollY == 300, "A duplicate shows the same page at the same place")
        precondition(copy.savedHistory.map(\.url) == source.savedHistory.map(\.url) && copy.historyIndex == source.historyIndex && copy.canGoBack,
                     "A duplicate carries its tab's back and forward history")
        restored.close(copy)
        restored.duplicate(restored.tabs[0])
        precondition(restored.tabs.count == 3 && restored.tabs[1].url == restored.tabs[0].url && restored.selectedID == restored.tabs[1].id,
                     "A duplicate opens beside its tab")
        restored.close(restored.tabs[1])
        print("PASS a duplicated tab opens beside it, selected, with its page, history and position")
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
