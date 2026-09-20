import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
#endif

private struct FilterTableRow: Identifiable {
    var rule: FilterRule
    var order: Int
    var id: String { rule.id }
    var name: String { rule.name.isEmpty ? "Unnamed filter" : rule.name }
    var matches: String { rule.summary }
    var effectText: String { rule.effectLabel }
    var status: String { rule.enabled ? "Active" : "Paused" }
}

struct FiltersView: View {
    @ObservedObject var store: RecordStore
    var openProfile: (String) -> Void
    @State private var selection = Set<String>()
    @State private var editing: String?
    @State private var mobileSort = "order"
    @State private var dragging: String?
    @State private var query = ""
    @State private var statusFilter = "all"
    @State private var effectFilter = "all"
    @State private var typeFilter = "all"
    @State private var sortOrder = [KeyPathComparator(\FilterTableRow.order)]
    @State private var deletions: [[RuleListEdits.Removed]] = []
    @State private var record: RecordDraft?
    @State private var showRecords = false
    @State private var profileToOpen: String?
    private var rows: [FilterTableRow] {
        store.archive.rules.enumerated().map { FilterTableRow(rule: $0.element, order: $0.offset + 1) }.filter { row in
            let people = row.rule.assignedUsers.compactMap { store.current($0) }
            let searchable = [row.name, row.matches, row.effectText] + Array(row.rule.assignedUsers) + people.flatMap { person in
                [person.note] + person.citations.flatMap { [$0.context, $0.excerpt, $0.annotation, $0.url] }
            }
            return (query.isEmpty || searchable.contains { $0.localizedCaseInsensitiveContains(query) }) &&
                (statusFilter == "all" || row.rule.enabled == (statusFilter == "active")) &&
                (effectFilter == "all" || row.rule.effect.rawValue == effectFilter) &&
                (typeFilter == "all" || (typeFilter == "account" ? !row.rule.assignedUsers.isEmpty : row.rule.conditions.isActive))
        }.sorted(using: sortOrder)
    }
    private var canReorder: Bool {
        query.isEmpty && statusFilter == "all" && effectFilter == "all" && typeFilter == "all" &&
        sortOrder == [KeyPathComparator(\FilterTableRow.order)]
    }
    var body: some View {
        VStack(spacing: 0) {
            controls
            Divider()
            bulkControls
            Divider()
            #if os(macOS)
            table
            #else
            mobileList
            #endif
            Divider()
            HStack {
                Text("\(rows.count) of \(store.archive.rules.count) filters").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !deletions.isEmpty {
                    Button("Undo deletion") { undoDeletion() }.keyboardShortcut("z", modifiers: .command)
                }
                Button("Saved notes") { showRecords = true }
            }.padding(12)
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("HackerViewsOpenReference"))) { _ in
            editing = nil; record = nil; showRecords = false; profileToOpen = nil
        }
        #if os(iOS)
        .navigationTitle("Filters")
        #endif
        .searchable(text: $query, prompt: "Search filters, notes, and citations")
        .onChange(of: rows.map(\.id)) { _, ids in
            selection.formIntersection(Set(ids))
        }
        .sheet(isPresented: Binding(get: { editing != nil }, set: { if !$0 { editing = nil } })) {
            if let id = editing { FilterEditor(store: store, id: id) }
        }
        .sheet(item: $record) { RecordEditor(store: store, draft: $0) }
        .sheet(isPresented: $showRecords, onDismiss: {
            if let username = profileToOpen {
                profileToOpen = nil
                openProfile(username)
            }
        }) {
            SavedNotesView(store: store) { username in
                profileToOpen = username
                showRecords = false
            }
        }
    }

    private var controls: some View {
        VStack(alignment: .leading, spacing: 10) {
            #if os(macOS)
            HStack { filterPickers; Spacer(); addButton }
            #else
            ScrollView(.horizontal, showsIndicators: false) { filterPickers.fixedSize() }
            addButton
            #endif
            #if os(iOS)
            Picker("Sort", selection: $mobileSort) {
                Text("Execution order").tag("order"); Text("Name").tag("name")
                Text("Effect").tag("effect"); Text("Status").tag("status")
            }.onChange(of: mobileSort) { _, value in
                switch value {
                case "name": sortOrder = [KeyPathComparator(\FilterTableRow.name)]
                case "effect": sortOrder = [KeyPathComparator(\FilterTableRow.effectText)]
                case "status": sortOrder = [KeyPathComparator(\FilterTableRow.status)]
                default: sortOrder = [KeyPathComparator(\FilterTableRow.order)]
                }
            }
            #endif
            HStack {
                Text(canReorder ? "First match wins. Drag to reorder; double-click a row to edit." : "Showing a filtered or sorted view. Execution order is unchanged.")
                    .font(.caption).foregroundStyle(.secondary)
                if !canReorder { Button("Reset view") { mobileSort = "order"; query = ""; statusFilter = "all"; effectFilter = "all"; typeFilter = "all"; sortOrder = [KeyPathComparator(\FilterTableRow.order)] }.font(.caption) }
            }
        }.padding(12)
    }
    private var filterPickers: some View {
        HStack {
            Picker("Status", selection: $statusFilter) { Text("All").tag("all"); Text("Active").tag("active"); Text("Paused").tag("paused") }
            Picker("Effect", selection: $effectFilter) { Text("All").tag("all"); Text("Block").tag("block"); Text("Highlight").tag("highlight"); Text("Fade").tag("fade"); Text("Show normally").tag("allow") }
            Picker("Match", selection: $typeFilter) { Text("All").tag("all"); Text("Assigned users").tag("account"); Text("Conditions").tag("conditions") }
        }.fixedSize(horizontal: false, vertical: true)
    }
    private var addButton: some View {
        Button {
            editing = UUID().uuidString
        } label: { Label("Add filter", systemImage: "plus") }
    }
    private var bulkControls: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 14) {
                Button("Select all shown") { selectAllInContext() }.keyboardShortcut("a", modifiers: .command)
                if !selection.isEmpty {
                    Text("\(selection.count) \(selection.count == 1 ? "filter" : "filters") selected").font(.caption)
                    Button("Clear") { selection.removeAll() }
                    Button("Activate") { updateSelected { $0.enabled = true } }
                    Button("Pause") { updateSelected { $0.enabled = false } }
                    Menu("Change effect") {
                        Button("Block") { updateSelected { $0.effect = .block } }
                        ForEach(FilterRule.FadeLevel.allCases, id: \.self) { level in
                            Button("Fade · " + level.label) { updateSelected { $0.effect = .fade; $0.fadeLevel = level } }
                        }
                        Button("Show normally") { updateSelected { $0.effect = .allow } }
                        ForEach(FilterRule.Accent.allCases, id: \.self) { color in
                            Button { updateSelected { $0.effect = .highlight; $0.color = color } } label: {
                                Label { Text("Highlight · " + color.rawValue.capitalized) } icon: { color.swatch }
                            }
                        }
                    }
                    Menu("Move") {
                        Button("To top") { moveSelected(toEnd: false) }
                        Button("To bottom") { moveSelected(toEnd: true) }
                    }
                    Button(role: .destructive) { delete(selection) } label: { Label("Delete", systemImage: "trash") }
                }
            }.buttonStyle(ControlSurfaceStyle()).padding(12)
        }
    }
    #if os(macOS)
    private var table: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn("Order", value: \.order) { row in
                HStack {
                    Image(systemName: "line.3.horizontal").foregroundStyle(canReorder ? Color.secondary : Color.clear)
                    Text("\(row.order)").monospacedDigit()
                }.contentShape(Rectangle())
                .onDrag { dragging = canReorder ? row.id : nil; return canReorder ? NSItemProvider(object: row.id as NSString) : NSItemProvider() }
                .onDrop(of: [UTType.text], isTargeted: nil) { _ in drop(on: row.id) }
            }.width(84)
            TableColumn("Name", value: \.name) { row in
                FilterNameField(text: Binding(get: {
                    store.archive.rules.first(where: { $0.id == row.id })?.name ?? ""
                }, set: { name in
                    update([row.id]) { $0.name = name }
                }), placeholder: "Filter name", active: row.rule.enabled,
                    accessibilityName: "Filter name, priority \(row.order)", coalescesEdits: true)
                .onDrop(of: [UTType.text], isTargeted: nil) { _ in drop(on: row.id) }
            }.width(min: 130, ideal: 190)
            TableColumn("Matches", value: \.matches) { row in Text(row.matches).foregroundStyle(.secondary).lineLimit(2) }.width(min: 160, ideal: 260)
            TableColumn("Effect", value: \.effectText) { row in effectMenu(row.rule) }.width(min: 160, ideal: 180)
            TableColumn("Status", value: \.status) { row in statusMenu(row.rule) }.width(100)
            TableColumn("Actions") { row in
                HStack(spacing: 4) {
                    Button { editing = row.id } label: { Image(systemName: "pencil") }.help("Edit filter")
                    Button { delete([row.id]) } label: { Image(systemName: "trash") }.help("Delete filter")
                }.buttonStyle(ControlSurfaceStyle()).foregroundStyle(.secondary)
            }.width(84)
        }
        .contextMenu(forSelectionType: String.self) { ids in
            Button("Edit filter") { editing = ids.first }.disabled(ids.count != 1)
            Button("Delete selected", role: .destructive) { delete(ids) }.disabled(ids.isEmpty)
        } primaryAction: { ids in if ids.count == 1 { editing = ids.first } }
    }
    #endif
    private var mobileList: some View {
        List {
            ForEach(rows) { row in
                HStack(alignment: .top) {
                    Button { if !selection.insert(row.id).inserted { selection.remove(row.id) } } label: {
                        Image(systemName: selection.contains(row.id) ? "checkmark.circle.fill" : "circle")
                    }.buttonStyle(ControlSurfaceStyle()).accessibilityLabel("Select \(row.name)")
                    VStack(alignment: .leading, spacing: 8) {
                        Button { editing = row.id } label: { Text("\(row.order). \(row.name)").font(.headline) }.buttonStyle(ControlSurfaceStyle())
                        Text(row.matches).font(.caption).foregroundStyle(.secondary)
                        HStack { effectMenu(row.rule); Spacer(); statusMenu(row.rule) }
                    }
                }.padding(.vertical, 5)
            }.onMove { from, to in
                guard canReorder else { return }
                var rules = store.archive.rules; rules.move(fromOffsets: from, toOffset: to); store.saveRules(rules)
            }.moveDisabled(!canReorder)
        }.listStyle(.plain)
    }
    private func statusMenu(_ rule: FilterRule) -> some View {
        Button {
            update([rule.id]) { $0.enabled.toggle() }
        } label: {
            Text(rule.enabled ? "Active" : "Paused")
                .font(.caption).foregroundStyle(rule.enabled ? Color.primary : Color.secondary)
                .padding(.vertical, 6).contentShape(Rectangle())
        }.buttonStyle(ControlSurfaceStyle()).fixedSize()
        .help(rule.enabled ? "Pause filter" : "Activate filter")
        .accessibilityLabel("\(rule.enabled ? "Pause" : "Activate") \(rule.name.isEmpty ? rule.summary : rule.name)")
    }
    private func selectAllInContext() {
        #if os(macOS)
        // The toolbar shortcut must not steal Select All from an active text editor.
        if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
            editor.selectAll(nil)
            return
        }
        #endif
        selection = Set(rows.map(\.id))
    }

    private func update(_ ids: Set<String>, edit: (inout FilterRule) -> Void) {
        var rules = store.archive.rules
        for i in rules.indices where ids.contains(rules[i].id) { edit(&rules[i]) }
        store.saveRules(rules)
    }
    private func updateSelected(_ edit: (inout FilterRule) -> Void) { update(selection, edit: edit) }
    private func moveSelected(toEnd: Bool) { store.saveRules(RuleListEdits.moving(selection, in: store.archive.rules, toEnd: toEnd)) }
    private func delete(_ ids: Set<String>) {
        let removed = RuleListEdits.removed(ids, from: store.archive.rules)
        guard !removed.isEmpty else { return }
        if store.saveRules(store.archive.rules.filter { !ids.contains($0.id) }) { deletions.append(removed); selection.subtract(ids) }
    }
    private func undoDeletion() {
        guard let last = deletions.last else { return }
        if store.saveRules(RuleListEdits.restoring(last, into: store.archive.rules)) { deletions.removeLast() }
    }
    private func drop(on id: String) -> Bool {
        guard canReorder, let source = dragging, source != id else { return false }
        var rules = store.archive.rules
        guard let from = rules.firstIndex(where: { $0.id == source }), let to = rules.firstIndex(where: { $0.id == id }) else { return false }
        rules.move(fromOffsets: IndexSet(integer: from), toOffset: from < to ? to + 1 : to)
        dragging = nil; return store.saveRules(rules)
    }
    private func effectMenu(_ rule: FilterRule) -> some View {
        FilterEffectPicker(rule: Binding(get: { rule }, set: { updated in
            update([rule.id]) { $0 = updated }
        }))
    }


}
extension FilterRule.Accent {
    private var rgb: (Double, Double, Double) {
        let value = UInt32(hex.dropFirst(), radix: 16) ?? 0
        return (Double((value >> 16) & 255) / 255, Double((value >> 8) & 255) / 255, Double(value & 255) / 255)
    }
    var swiftUI: Color {
        let (r, g, b) = rgb
        return Color(red: r, green: g, blue: b)
    }
    // Native menus tint SF Symbols with the app accent. An original-color image
    // preserves each swatch's actual RGB value in both the menu and selection.
    var swatch: Image {
        let (r, g, b) = rgb
        #if os(macOS)
        let image = NSImage(size: NSSize(width: 16, height: 16), flipped: false) { _ in
            NSColor(srgbRed: r, green: g, blue: b, alpha: 1).setFill()
            NSBezierPath(ovalIn: NSRect(x: 2, y: 2, width: 12, height: 12)).fill()
            return true
        }
        image.isTemplate = false
        return Image(nsImage: image).renderingMode(.original)
        #else
        let image = UIGraphicsImageRenderer(size: CGSize(width: 16, height: 16)).image { context in
            UIColor(red: r, green: g, blue: b, alpha: 1).setFill()
            context.cgContext.fillEllipse(in: CGRect(x: 2, y: 2, width: 12, height: 12))
        }
        return Image(uiImage: image.withRenderingMode(.alwaysOriginal)).renderingMode(.original)
        #endif
    }
}
extension FilterRule {
    var effectLabel: String {
        switch effect { case .block: "Block"; case .highlight: "Highlight · " + color.rawValue.capitalized; case .allow: "Show normally"; case .fade: "Fade · " + fade.label }
    }
    var summary: String {
        var values: [String] = []
        let higher = conditions.preferHigher == true
        if let karma = conditions.karmaBelow { values.append("karma \((conditions.karmaHigher ?? higher) ? "≥" : "<") \(karma)") }
        if let date = conditions.createdSince { values.append("created \((conditions.createdEarlier ?? higher) ? "before" : "on/after") \(date.formatted(date: .abbreviated, time: .omitted))") }
        if let days = conditions.youngerThanDays { values.append("age \((conditions.ageOlder ?? higher) ? "≥" : "<") \(days) days") }
        let predicate = values.joined(separator: conditions.match == .any ? " OR " : " AND ")
        var groups: [String] = []
        if !assignedUsers.isEmpty { groups.append("\(assignedUsers.count) assigned users") }
        if !predicate.isEmpty { groups.append("(" + predicate + ")") }
        if let content { groups.append(content.field.rawValue + " " + content.mode.rawValue + " " + (content.activePatterns.count > 1 ? content.summary : "“" + content.summary + "”")) }
        var result = groups.joined(separator: combine == .all ? " AND " : " OR ")
        if !(itemIDs ?? []).isEmpty { result = "\((itemIDs ?? []).count) direct items" + (result.isEmpty ? "" : "; " + result) }
        if result.isEmpty { result = "No users, items, or conditions" }
        return (scope == .posts ? "Posts · " : scope == .comments ? "Comments · " : "") + result
    }
}
