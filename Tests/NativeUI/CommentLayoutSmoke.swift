import AppKit
import WebKit

@main struct CommentLayoutSmoke {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let view = WKWebView(frame: NSRect(x: 0, y: 0, width: 850, height: 600))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 850, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = view
        window.orderBack(nil)
        let source = try! String(contentsOfFile: "HackerViews/Resources/filter.js", encoding: .utf8)
        let config = view.configuration.userContentController
        config.addUserScript(WKUserScript(source: "window.webkit={messageHandlers:{hackerViews:{postMessage:()=>{}}}};window.__hackerViewsBlocked=[];", injectionTime: .atDocumentStart, forMainFrameOnly: true))
        config.addUserScript(WKUserScript(source: source, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let rows = [0,40,80].map { depth in
            """
            <tr class="athing comtr" id="\(depth + 1)"><td><table><tbody><tr>
            <td class="ind" indent="\(depth)"><img width="\(depth)" height="1"></td>
            <td class="votelinks"><a href="#"><div class="votearrow"></div></a><a href="#"><div class="votearrow rotate180"></div></a></td>
            <td class="default"><div><span class="comhead"><a class="hnuser">author</a> 1 hour ago <a class="togg">[–]</a></span></div>
            <div class="comment"><span class="commtext">\(String(repeating: "Long comment text to exercise table sizing. ", count: 12))</span></div></td>
            </tr></tbody></table></td></tr>
            """
        }.joined()
        view.loadHTMLString("<style>.nosee{visibility:hidden}.noshow{display:none}.votearrow{width:10px;height:10px;margin:3px 2px 6px}.votelinks.nosee .rotate180{display:none}</style><table class='comment-tree'>\(rows)</table>", baseURL: URL(string: "https://news.ycombinator.com/news"))
        Task { @MainActor in
            while view.isLoading { try? await Task.sleep(for: .milliseconds(50)) }
            try? await Task.sleep(for: .milliseconds(200))
            for width in [850, 500] {
                view.setFrameSize(NSSize(width: width, height: 600))
                let result = try! await view.evaluateJavaScript("""
                (()=>{
                  const failures=[];
                  for(const row of document.querySelectorAll('.comtr')) {
                    const cell=row.querySelector('.default'), votes=row.querySelector('.votelinks'), body=row.querySelector('.comment'), toggle=row.querySelector('.togg');
                    const before=cell.getBoundingClientRect().x;
                    row.classList.add('coll');votes.classList.add('nosee');body.classList.add('noshow');toggle.textContent='[103 more]';
                    const collapsed=cell.getBoundingClientRect().x;
                    row.classList.remove('coll');votes.classList.remove('nosee');body.classList.remove('noshow');toggle.textContent='[–]';
                    const expanded=cell.getBoundingClientRect().x;
                    if(Math.abs(before-collapsed)>0.5 || Math.abs(before-expanded)>0.5) failures.push({before,collapsed,expanded});
                  }
                  return JSON.stringify(failures);
                })()
                """) as! String
                precondition(result == "[]", "Indentation shifted at width \(width): \(result)")
            }
            window.setContentSize(NSSize(width: 850, height: 250))
            _ = try! await view.evaluateJavaScript("window.scrollTo(0,document.getElementById('41').getBoundingClientRect().top+scrollY+30)")
            try? await Task.sleep(for: .milliseconds(150))
            let resizeTop = try! await view.evaluateJavaScript("document.getElementById('41').getBoundingClientRect().top") as! Double
            for width in [500, 850, 600, 850] {
                window.setContentSize(NSSize(width: width, height: 250))
                try? await Task.sleep(for: .milliseconds(150))
                let top = try! await view.evaluateJavaScript("document.getElementById('41').getBoundingClientRect().top") as! Double
                precondition(abs(top-resizeTop)<2, "Width \(width) moved reading anchor: \(resizeTop) to \(top)")
            }
            print("PASS WebKit: narrowing and widening preserve the top comment offset")
            window.setContentSize(NSSize(width: 850, height: 600))
            try? await Task.sleep(for: .milliseconds(100))
            view.appearance = NSAppearance(named: .darkAqua)
            try? await Task.sleep(for: .milliseconds(100))
            let links = try! await view.evaluateJavaScript("""
            (() => {
              const host = document.createElement('div');
              host.innerHTML = '<style>.c00 a:link {color:#000}.c5a a:link {color:#5a5a5a}</style>' +
                '<div class="qhn-preferred"><span class="commtext c00"><a href="https://example.com/one">Highlighted link</a></span></div>' +
                '<div class="qhn-faded"><span class="commtext c5a"><a href="https://example.com/two">Faded link</a></span></div>';
              document.body.append(host);
              return [...host.querySelectorAll('a')].map(a => getComputedStyle(a).color).join('|');
            })()
            """) as! String
            precondition(links == "rgb(238, 160, 108)|rgb(238, 160, 108)", "Dark link colors: \(links)")
            let voteGeometry = try! await view.callAsyncJavaScript("""
            return await (async()=>{
              document.body.innerHTML='<main id="hv-topic-root"></main>';document.body.dataset.hvTopic='1';
              window.HackerViews.retry();
              window.HackerViews.lazyResult(1,[{id:1,effect:'visible',item:{id:1,type:'comment',by:'reader',text:'Comment',parent:99,kids:[2,3]}}]);
              await new Promise(requestAnimationFrame);
              const buttons=[...document.querySelectorAll('.hv-vote')];
              // Geometry fixture supplies confirmed eligibility; network eligibility is tested separately.
              buttons.forEach(button=>button.hidden=false);
              const up=buttons[0].getBoundingClientRect(),down=buttons[1].getBoundingClientRect();
              const row=document.getElementById('1'),cell=row.querySelector('.default'),before=cell.getBoundingClientRect().x;
              row.querySelector('.hv-collapse').click();
              const collapsed=cell.getBoundingClientRect().x;
              if(!buttons[0].closest('.comhead'))return 'arrows not inline in the header';
              row.querySelector('.hv-collapse').click();
              if(Math.abs(before-collapsed)>.5)return 'collapse shifted gutter';
              if(Math.abs(up.y-down.y)>.5 || down.x<up.right || up.width!==15 || up.height!==14)return JSON.stringify({up,down});
              if(buttons.some(b=>b.textContent || getComputedStyle(b).appearance!=='none'))return 'native button styling or text glyph';
              const record=row.querySelector('.qhn-record');
              const reference=record.cloneNode(true);document.body.append(reference);
              const actual=getComputedStyle(record),expected=getComputedStyle(reference);
              for(const property of ['backgroundColor','color','borderWidth','borderRadius','padding','fontSize']) {
                if(actual[property]!==expected[property])return 'ellipsis style mismatch: '+property;
              }
              if(actual.backgroundColor!=='rgba(0, 0, 0, 0)' || actual.borderWidth!=='0px')return 'ellipsis has permanent chrome';
              reference.remove();
              return 'ok';
            })()
            """, arguments: [:], in: nil, contentWorld: .page) as! String
            precondition(voteGeometry == "ok", "Vote geometry: \(voteGeometry)")
            let nextNavigation = try! await view.callAsyncJavaScript("""
            return await new Promise(resolve=>setTimeout(()=>{
              window.HackerViews.lazyResult(2,[2,3].map(id=>({id,effect:'visible',item:{id,type:'comment',by:'reader',parent:1,text:'Long comment. '.repeat(600)}})));
              setTimeout(()=>{
                const next=[...document.getElementById('2').querySelectorAll('.hv-comment-nav a')].find(a=>a.textContent==='next');
                next.click();
                const target=document.getElementById('3').closest('.hv-node');
                resolve(window.scrollY>0 && Math.abs(target.getBoundingClientRect().top)<2 ? 'ok' : 'did not scroll to sibling');
              },20);
            },20))
            """, arguments: [:], in: nil, contentWorld: .page) as! String
            precondition(nextNavigation == "ok", "Next navigation: \(nextNavigation)")
            print("PASS WebKit next scrolls to offscreen sibling inside current discussion")
            print("PASS WebKit lazy vote controls: inline side-by-side arrows, compact dimensions, stable collapse gutter")
            print("PASS WebKit dark link contrast overrides HN score colors")
            print("PASS WebKit comment geometry: collapse/reopen at three depths and two widths")
            exit(0)
        }
        app.run()
    }
}
