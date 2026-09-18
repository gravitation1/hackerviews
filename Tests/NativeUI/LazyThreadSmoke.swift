import AppKit
import WebKit

actor ItemRequests {
    var ids: [Int] = []
    func item(_ id: Int) -> HNItem {
        ids.append(id)
        if id == 1 { return HNItem(id:1,by:"author",parent:nil,type:"story",title:"Lazy discussion",kids:Array(2...10001),score:42,descendants:10000) }
        return HNItem(id:id,by:"reader",parent:1,text:String(repeating:"A long comment. ",count:150),kids:[])
    }
}
@main struct LazyThreadSmoke {
    @MainActor static func main() {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let dir=FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let requests=ItemRequests()
        let service=HNService(directory:dir,itemLoader:{id in let item=await requests.item(id); try await Task.sleep(for:.milliseconds(id == 1 ? 750 : id == 2 ? 1800 : 50)); return item})
        let store=RecordStore(directory:dir)
        let tab=BrowserTab(store:store,service:service,persistentSession:false)
        let view=tab.webView
        let controller=view.configuration.userContentController
        controller.removeAllUserScripts()
        let source=try! String(contentsOfFile:"HackerViews/Resources/filter.js",encoding:.utf8)
        controller.addUserScript(WKUserScript(source:"window.__hackerViewsOrdered=true;window.__hackerViewsOrderedActive=false;"+source,injectionTime:.atDocumentStart,forMainFrameOnly:true,in:WKContentWorld.world(name:"HackerViews")))
        let window=NSWindow(contentRect:NSRect(x:-10000,y:-10000,width:700,height:500),styleMask:[.titled],backing:.buffered,defer:false)
        window.contentView=view;window.orderBack(nil)
        tab.restoreScrollY=1500
        tab.load(URL(string:"https://news.ycombinator.com/item?id=1")!)
        Task { @MainActor in
            try? await Task.sleep(for:.milliseconds(300))
            precondition(tab.state == .ready,"The shell must be usable before the slow story request finishes")
            try? await Task.sleep(for:.milliseconds(1000))
            let independent=try! await view.evaluateJavaScript("document.getElementById('3') !== null && document.getElementById('2') === null") as! Bool
            precondition(independent,"Fast sibling must render before the delayed sibling completes")
            try? await Task.sleep(for:.seconds(2))
            let ids=await requests.ids
            let location=try! await view.evaluateJavaScript("location.href")
            print("location",location as Any,"state",tab.state,"requests",ids)
            precondition(tab.state == .ready,"Shell should become ready without full topic download")
            precondition(ids.contains(1) && ids.count > 65,"Must continue fetching beyond the initial viewport")
            let count=try! await view.evaluateJavaScript("document.querySelectorAll('.comtr').length") as! Int
            precondition(count > 0)
            let position=try! await view.evaluateJavaScript("window.scrollY") as! Double
            precondition(abs(position-1500)<2,"Restore position after enough comments are loaded")
            let title=try! await view.evaluateJavaScript("document.title") as! String
            precondition(title.contains("Lazy discussion"))
            // Change the old page's height so a pixel-only restore cannot pass.
            _ = try! await view.evaluateJavaScript("document.getElementById('hv-topic-root').insertAdjacentHTML('afterbegin', '<div style=\"height:200px\"></div>')")
            let anchor = try! await view.evaluateJavaScript("""
                (()=>{const row=[...document.querySelectorAll('tr.athing')].find(r=>r.getClientRects().length && r.getBoundingClientRect().bottom>0);
                return {id:row.id,top:row.getBoundingClientRect().top};})()
                """) as! [String: Any]
            tab.reload()
            try? await Task.sleep(for: .seconds(2))
            let restoredTop = try! await view.evaluateJavaScript("document.getElementById('" + (anchor["id"] as! String) + "').getBoundingClientRect().top") as! Double
            precondition(abs(restoredTop - (anchor["top"] as! Double)) < 2, "Refresh must restore the contribution offset despite changed page height")
            precondition(tab.state == .ready)
            print("PASS real WebKit: refresh restores the same contribution and offset after layout changes")
            let beforeScroll = await requests.ids
            _ = try! await view.evaluateJavaScript("window.scrollTo(0,document.documentElement.scrollHeight)")
            try? await Task.sleep(for:.seconds(1))
            let after=await requests.ids
            precondition(after.count >= beforeScroll.count,"Loading must continue across scrolling")
            print("PASS real WebKit: 10,000-comment topic opens immediately and continues background loading with viewport/restoration priority")
            let world = WKContentWorld.world(name: "HackerViews")
            _ = try! await view.callAsyncJavaScript("""
                window.webkit.messageHandlers.hackerViews.postMessage({kind:'cancelLazy'});
                window.receivedBatches = new Set();
                window.HackerViews.lazyResult = (token, entries) => {
                    if(token>=50000 && entries.length) window.receivedBatches.add(token);
                };
                for(let id=50000;id<50040;id++)
                    window.webkit.messageHandlers.hackerViews.postMessage({kind:'lazyItems',ids:[id],token:id,visible:true});
                """, arguments: [:], in: nil, contentWorld: world)
            try? await Task.sleep(for: .seconds(2))
            let accepted = try! await view.callAsyncJavaScript("return window.receivedBatches.size", arguments: [:], in: nil, contentWorld: world) as! Int
            precondition(accepted == 40, "The native bridge must queue every valid batch, never silently discard at capacity")
            print("PASS real WebKit: all 40 queued batches receive a terminal result")
            try? FileManager.default.removeItem(at:dir)
            exit(0)
        }
        app.run()
    }
}
