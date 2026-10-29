import SwiftUI
import AppKit

/// The tab strip under real mouse events: a click still selects or closes, a
/// drag moves a tab past the tabs whose middles its leading edge crosses, the
/// order changes only once the tab is let go, and the selection stays with its
/// tab.
@main struct TabReorderSmoke {
    final class KeyWindow: NSWindow { override var canBecomeKey: Bool { true } }

    @MainActor static func main() {
        setvbuf(stdout, nil, _IONBF, 0)
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        let suite = "HackerViews.TabReorderTest." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = RecordStore(directory: directory)
        let workspace = BrowserWorkspace(store: store, defaults: defaults, persistentSession: false)
        for title in ["Alpha", "Bravo", "Charlie has a longer title", "Delta"] {
            let tab = BrowserTab(store: store, service: HNService.shared, persistentSession: false)
            tab.title = title
            workspace.tabs.append(tab)
        }
        workspace.selectedID = workspace.tabs[0].id
        let visible = NSScreen.main!.visibleFrame
        let window = KeyWindow(contentRect: NSRect(x: visible.maxX - 900, y: visible.minY, width: 900, height: 60),
                               styleMask: [.borderless], backing: .buffered, defer: false)
        window.level = .floating
        window.contentView = NSHostingView(rootView: TabStrip(workspace: workspace))
        window.orderFrontRegardless()
        window.makeKey()
        defer { window.orderOut(nil) }

        func spin(_ seconds: TimeInterval) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
        func titles() -> String { workspace.tabs.map { String($0.title.prefix(1)) }.joined() }
        /// Each button's frame in window coordinates, left to right, from the
        /// focus ring view SwiftUI gives every button: without an accessibility
        /// client SwiftUI builds no accessibility tree to find them by.
        func buttons() -> [NSRect] {
            func rings(_ view: NSView) -> [NSView] {
                (String(describing: type(of: view)).contains("FocusRing") ? [view] : []) + view.subviews.flatMap(rings)
            }
            return rings(window.contentView!).map { $0.convert($0.bounds, to: nil) }.sorted { $0.minX < $1.minX }
        }
        /// A tab's title or close button, by its title, with the strip at rest.
        func frame(_ title: String, close: Bool = false) -> NSRect {
            let frames = buttons(), index = workspace.tabs.firstIndex { $0.title == title }!
            precondition(frames.count == workspace.tabs.count * 2, "two buttons per tab, found \(frames.count)")
            return frames[index * 2 + (close ? 1 : 0)]
        }
        func send(_ type: NSEvent.EventType, _ point: NSPoint) {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            spin(0.02)
        }
        func click(_ point: NSPoint) { send(.leftMouseDown, point); send(.leftMouseUp, point) }
        /// Press at `start`, move by `dx` in steps, and let go unless `hold`.
        func drag(_ start: NSPoint, by dx: CGFloat, hold: Bool = false) {
            send(.leftMouseDown, start)
            for step in 1...12 { send(.leftMouseDragged, NSPoint(x: start.x + dx * CGFloat(step) / 12, y: start.y)) }
            if !hold { send(.leftMouseUp, NSPoint(x: start.x + dx, y: start.y)); spin(0.4) }
        }
        func middle(_ rect: NSRect) -> NSPoint { NSPoint(x: rect.midX, y: rect.midY) }
        spin(0.3)

        let bravo = frame("Bravo")
        click(middle(bravo)); spin(0.2)
        precondition(workspace.selected?.title == "Bravo" && titles() == "ABCD", "a click selects its tab and moves nothing, got \(titles())")
        print("PASS a click on a tab selects it")

        let alpha = frame("Alpha")
        drag(middle(alpha), by: bravo.maxX - alpha.maxX, hold: true)
        precondition(titles() == "ABCD", "the order holds while the tab is dragged")
        send(.leftMouseUp, NSPoint(x: middle(alpha).x + bravo.maxX - alpha.maxX, y: alpha.midY)); spin(0.4)
        precondition(titles() == "BACD", "let go past Bravo's middle, Alpha lands after it, got \(titles())")
        precondition(workspace.selected?.title == "Bravo", "a drag selects nothing and the selection stays with its tab")
        print("PASS a dragged tab opens a gap, lands in it on release, and leaves the selection alone")

        drag(middle(frame("Charlie has a longer title")), by: -2000)
        precondition(titles() == "CBAD", "dragged past the front, a wide tab lands first, got \(titles())")
        drag(middle(frame("Charlie has a longer title")), by: 10)
        precondition(titles() == "CBAD", "a short drag moves nothing, got \(titles())")
        drag(middle(frame("Charlie has a longer title")), by: 2000)
        precondition(titles() == "BADC", "dragged past the end, it lands last, got \(titles())")
        print("PASS tabs reach either end of the strip and a short drag moves nothing")

        drag(middle(frame("Delta", close: true)), by: -2000)
        precondition(titles() == "DBAC" && workspace.tabs.count == 4, "a drag from the close button moves the tab without closing it, got \(titles())")
        click(middle(frame("Alpha", close: true))); spin(0.3)
        precondition(titles() == "DBC", "a click on the close button still closes, got \(titles())")
        print("PASS the close button drags its tab and still closes on a click")
    }
}
