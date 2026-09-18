import AppKit
import WebKit

actor HistoryRequests {
    var count = 0
    func item(_ id: Int) -> HNItem {
        count += 1
        if id == 100 { return HNItem(id: id, by: "author", parent: nil, type: "story", title: "History fixture", kids: Array(101...150)) }
        return HNItem(id: id, by: "reader", parent: 100, text: String(repeating: "Comment text. ", count: 80), kids: [])
    }
}
@main struct HistoryPageSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.prohibited)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let requests = HistoryRequests()
        let service = HNService(directory: directory, itemLoader: { await requests.item($0) })
        let store = RecordStore(directory: directory)
        let tab = BrowserTab(store: store, service: service, persistentSession: false, retainsPages: true)
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 700, height: 500), styleMask: [.titled], backing: .buffered, defer: false)
        let world = WKContentWorld.world(name: "HackerViews")
        func mount() { window.contentView = tab.webView; window.orderBack(nil); tab.displayedPage.restoreRetainedViewport() }
        tab.load(URL(string: "https://news.ycombinator.com/item?id=100")!)
        mount()
        Task { @MainActor in
            for _ in 0..<200 {
                let count = (try? await tab.webView.evaluateJavaScript("document.querySelectorAll('.comtr').length")) as? Int ?? 0
                if count == 50 { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let thread = tab.displayedPage
            let threadView = tab.webView
            let count = try! await threadView.evaluateJavaScript("document.querySelectorAll('.comtr').length") as! Int
            precondition(count == 50)
            _ = try! await threadView.evaluateJavaScript("window.historySentinel='retained'; document.getElementById('120').scrollIntoView(); window.scrollBy(0,25)")
            try? await Task.sleep(for: .milliseconds(300))
            let before = try! await threadView.callAsyncJavaScript("return window.HackerViews.readingPosition()", arguments: [:], in: nil, contentWorld: world) as! [String: Any]
            let id = before["id"] as! Int, top = before["top"] as! Double
            let requestCount = await requests.count
            _ = try! await threadView.evaluateJavaScript("document.querySelector('.hv-header .hv-nav a').click()")
            for _ in 0..<50 {
                if tab.displayedPage !== thread { break }
                try? await Task.sleep(for: .milliseconds(20))
            }
            precondition(tab.displayedPage !== thread && tab.url?.path == "/", "Home links must create a separate retained history page")
            let home = tab.displayedPage
            home.webView.stopLoading()
            home.webView.loadHTMLString("<html><body><p>Home fixture</p><div style='height:3000px'></div></body></html>", baseURL: URL(string: "https://news.ycombinator.com/")!)
            mount()
            try? await Task.sleep(for: .seconds(1))
            _ = try! await home.webView.evaluateJavaScript("window.historySentinel='home'; window.scrollTo(0,400)")
            try? await Task.sleep(for: .milliseconds(300))
            for _ in 0..<5 {
                tab.back(); mount()
                precondition(tab.displayedPage === thread && tab.webView === threadView)
                try? await Task.sleep(for: .milliseconds(300))
                let marker = try! await threadView.evaluateJavaScript("window.historySentinel") as! String
                let restoredTop = try! await threadView.evaluateJavaScript("document.getElementById('\(id)').getBoundingClientRect().top") as! Double
                precondition(marker == "retained" && abs(restoredTop - top) < 2, "History must retain document and comment offset")
                let activeY = tab.scrollY
                home.saveReadingPosition(y: 2900, anchor: nil)
                precondition(tab.scrollY == activeY, "Inactive page reports cannot change destination position")
                tab.forward(); mount()
                precondition(tab.displayedPage === home)
                try? await Task.sleep(for: .milliseconds(300))
                let homeY = try! await home.webView.evaluateJavaScript("window.scrollY") as! Double
                precondition(abs(homeY - 400) < 2)
            }
            for _ in 0..<5 { tab.back(); mount(); tab.forward(); mount() }
            try? await Task.sleep(for: .milliseconds(500))
            tab.back(); mount()
            try? await Task.sleep(for: .milliseconds(500))
            let rapidTop = try! await threadView.evaluateJavaScript("document.getElementById('\(id)').getBoundingClientRect().top") as! Double
            precondition(abs(rapidTop - top) < 2, "Rapid navigation must not overwrite the destination anchor")
            let finalCount = await requests.count
            precondition(finalCount == requestCount, "History must not request comments again")
            _ = try! await threadView.evaluateJavaScript("document.getElementById('125').querySelector('.hv-collapse').click(); document.getElementById('130')?.querySelector('.hv-collapse').click()")
            tab.reload()
            for _ in 0..<100 {
                let ready = (try? await threadView.evaluateJavaScript("document.getElementById('130')?.querySelector('.hv-collapse')?.getAttribute('aria-expanded') === 'false'")) as? Bool ?? false
                if ready { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let collapsed = try! await threadView.evaluateJavaScript("[125,130].every(id=>document.getElementById(String(id))?.querySelector('.hv-collapse')?.getAttribute('aria-expanded') === 'false')") as! Bool
            precondition(collapsed, "Refresh must restore collapsed comment bodies")
            let saved = try! JSONEncoder().encode(tab.savedHistory)
            let reopened = BrowserTab(store: store, service: service, persistentSession: false, retainsPages: true)
            reopened.restoreHistory(try! JSONDecoder().decode([BrowserTab.HistoryEntry].self, from: saved), index: tab.historyIndex)
            reopened.load(tab.url!)
            window.contentView = reopened.webView
            for _ in 0..<100 {
                let ready = (try? await reopened.webView.evaluateJavaScript("document.getElementById('130')?.querySelector('.hv-collapse')?.getAttribute('aria-expanded') === 'false'")) as? Bool ?? false
                if ready { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            let reopenedCollapsed = try! await reopened.webView.evaluateJavaScript("[125,130].every(id=>document.getElementById(String(id))?.querySelector('.hv-collapse')?.getAttribute('aria-expanded') === 'false')") as! Bool
            precondition(reopenedCollapsed, "A newly constructed reader must restore collapsed threads from its serialized session")
            print("PASS real WebKit: serialized history restores collapsed comments in a newly constructed reader")
            print("PASS real WebKit: refresh preserves multiple collapsed comments")
            print("PASS real WebKit: repeated and rapid thread/home round trips retain documents, comment offset, home position and request count; inactive reports are ignored")
            try? FileManager.default.removeItem(at: directory)
            exit(0)
        }
        app.run()
    }
}
