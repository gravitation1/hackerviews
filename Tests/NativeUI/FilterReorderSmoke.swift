import AppKit
import ObjectiveC
import SwiftUI

/// The Filters table's drag and drop, through the table's own data source:
/// a row drags from any cell but its name, a drop over a row becomes a drop
/// into the gap below it (where the insertion line is drawn), the dropped rows
/// land in that gap whichever way they travelled, and a filtered view, whose
/// order is not the execution order, takes no drops.
@main struct FilterReorderSmoke {
    @MainActor static var retargets: [(item: Any?, index: Int)] = []

    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        setvbuf(stdout, nil, _IONBF, 0)
        recordDropRetargets()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = RecordStore(directory: dir)
        func rule(_ name: String) -> FilterRule { var rule = FilterRule(); rule.name = name; rule.effect = .block; rule.members = []; return rule }
        precondition(store.saveRules(["A", "B", "C", "D", "E", "F"].map(rule)))
        func names() -> String { store.archive.rules.map(\.name).joined() }
        let view = NSHostingView(rootView: FiltersView(store: store, query: .constant(""), openProfile: { _ in }))
        let window = NSWindow(contentRect: NSRect(x: -10000, y: -10000, width: 1100, height: 520), styleMask: [.titled], backing: .buffered, defer: false)
        view.frame = NSRect(x: 0, y: 0, width: 1100, height: 520)
        window.contentView = view
        window.orderBack(nil)
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            // SwiftUI's Table is an outline view whose rows are root items.
            guard let table = find(NSOutlineView.self, in: view), let source = table.dataSource else { fatalError("no table") }
            precondition(table.numberOfRows == 6)
            precondition(!table.registeredDraggedTypes.isEmpty, "the table accepts drops")
            let middle = table.frameOfCell(atColumn: 2, row: 1)
            precondition(table.canDragRows(with: [1], at: NSPoint(x: middle.midX, y: middle.midY)), "a row drags from its Matches cell")

            /// Drop rows onto the proposed root index, or onto the row at that index.
            @MainActor func drop(_ rows: [Int], proposedIndex: Int, onto: Bool = false) async -> (item: Any?, index: Int) {
                let pasteboard = NSPasteboard(name: NSPasteboard.Name("hv-reorder-\(UUID().uuidString)"))
                pasteboard.clearContents()
                let writers = rows.compactMap { source.outlineView?(table, pasteboardWriterForItem: table.item(atRow: $0)!) }
                precondition(writers.count == rows.count, "every row has a drag payload")
                pasteboard.writeObjects(writers)
                let frame = table.rect(ofRow: min(proposedIndex, table.numberOfRows - 1))
                let point = table.convert(NSPoint(x: frame.midX, y: frame.midY), to: nil)
                let info = Dragging(pasteboard: pasteboard, source: table, window: window, location: point)
                retargets.removeAll()
                let item = onto ? table.item(atRow: proposedIndex) : nil, index = onto ? NSOutlineViewDropOnItemIndex : proposedIndex
                let proposed = source.outlineView?(table, validateDrop: info, proposedItem: item, proposedChildIndex: index) ?? []
                let final = retargets.last ?? (item, index)
                precondition(!proposed.isEmpty, "the drop is accepted")
                _ = source.outlineView?(table, acceptDrop: info, item: final.item, childIndex: final.index)
                for _ in 0..<40 where store.archive.rules.count == 6 { try? await Task.sleep(for: .milliseconds(25)) }
                try? await Task.sleep(for: .milliseconds(200))
                pasteboard.releaseGlobally()
                return final
            }

            // AppKit proposes the gap nearest the pointer by a row's edges and
            // the row itself in its middle; the table moves the latter to the
            // gap below, so the line it draws always sits between two rows.
            let onto = await drop([0], proposedIndex: 3, onto: true)
            precondition(onto.item == nil && onto.index == 4, "a drop over a row goes into the gap below it, got \(onto)")
            precondition(names() == "BCDAEF", "A dropped over D lands between D and E, got \(names())")
            _ = await drop([4], proposedIndex: 1)
            precondition(names() == "BECDAF", "dragging up lands in the gap, got \(names())")
            _ = await drop([0], proposedIndex: 3)
            precondition(names() == "ECBDAF", "dragging down lands in the gap, got \(names())")
            _ = await drop([0], proposedIndex: 6)
            precondition(names() == "CBDAFE", "the gap below the last row moves to the end, got \(names())")
            _ = await drop([1, 3], proposedIndex: 0)
            precondition(names() == "BACDFE", "several rows move together and keep their order, got \(names())")
            _ = await drop([2], proposedIndex: 2)
            precondition(names() == "BACDFE", "a drop into a row's own gap changes nothing, got \(names())")
            let filtered = NSHostingView(rootView: FiltersView(store: store, query: .constant("A"), openProfile: { _ in }))
            filtered.frame = view.frame
            window.contentView = filtered
            try? await Task.sleep(for: .milliseconds(500))
            guard let other = find(NSOutlineView.self, in: filtered) else { fatalError("no filtered table") }
            precondition(other.numberOfRows == 1)
            let accepted = other.dataSource?.outlineView?(other, validateDrop: Dragging(pasteboard: NSPasteboard(name: NSPasteboard.Name("hv-reorder-empty")), source: other, window: window, location: .zero), proposedItem: nil, proposedChildIndex: 0) ?? []
            precondition(other.registeredDraggedTypes.isEmpty || accepted.isEmpty, "a filtered view takes no drops")
            print("PASS: rows drag from any cell but the name, drops land in the gap marked by the insertion line, in either direction and for several rows; a filtered view takes none")
            try? FileManager.default.removeItem(at: dir)
            exit(0)
        }
        app.run()
    }

    @MainActor static func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
        if let match = view as? T { return match }
        for child in view.subviews { if let match = find(type, in: child) { return match } }
        return nil
    }

    /// Record where the data source moves a proposed drop.
    @MainActor static func recordDropRetargets() {
        let selector = #selector(NSOutlineView.setDropItem(_:dropChildIndex:))
        guard let method = class_getInstanceMethod(NSOutlineView.self, selector) else { fatalError("no setDropItem") }
        typealias Original = @convention(c) (NSOutlineView, Selector, Any?, Int) -> Void
        let original = unsafeBitCast(method_getImplementation(method), to: Original.self)
        let block: @convention(block) (NSOutlineView, Any?, Int) -> Void = { table, item, index in
            MainActor.assumeIsolated { retargets.append((item, index)) }
            original(table, selector, item, index)
        }
        method_setImplementation(method, imp_implementationWithBlock(block))
    }
}

/// A drag in progress from the table onto itself.
@MainActor final class Dragging: NSObject, @preconcurrency NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingDestinationWindow: NSWindow?
    let draggingLocation: NSPoint
    init(pasteboard: NSPasteboard, source: Any?, window: NSWindow?, location: NSPoint) {
        draggingPasteboard = pasteboard; draggingSource = source; draggingDestinationWindow = window; draggingLocation = location
    }
    var draggingSourceOperationMask: NSDragOperation { [.move, .copy, .generic] }
    var draggedImageLocation: NSPoint { .zero }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    var draggingFormation: NSDraggingFormation { get { .default } set {} }
    var animatesToDestination: Bool { get { false } set {} }
    var numberOfValidItemsForDrop: Int { get { draggingPasteboard.pasteboardItems?.count ?? 0 } set {} }
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes classArray: [AnyClass], searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {
        var stop = ObjCBool(false)
        for (index, object) in (draggingPasteboard.readObjects(forClasses: classArray, options: searchOptions) ?? []).enumerated() {
            guard let writer = object as? NSPasteboardWriting else { continue }
            block(NSDraggingItem(pasteboardWriter: writer), index, &stop)
            if stop.boolValue { break }
        }
    }
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func resetSpringLoading() {}
}
