import SwiftUI

struct FilterEditor: View {
    @ObservedObject var store: RecordStore
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var rule: FilterRule
    @State private var membershipBase: Set<String>
    @State private var karma: String
    @State private var days: String
    @State private var useKarma: Bool
    @State private var useAge: Bool
    @State private var useDate: Bool
    @State private var date: Date
    @State private var record: RecordDraft?
    @State private var showAuthors = false
    @State private var advancedGrouping = false
    @State private var saveFailed = false
    @State private var saveTask: Task<Void, Never>?
    private let isNew: Bool
    init(store: RecordStore, id: String) {
        self.store = store; self.id = id
        self.isNew = !store.archive.rules.contains(where: { $0.id == id })
        var value = store.archive.rules.first { $0.id == id } ?? FilterRule()
        value.id = id
        value.conditions.karmaHigher = value.conditions.karmaHigher ?? value.conditions.preferHigher ?? false
        value.conditions.createdEarlier = value.conditions.createdEarlier ?? value.conditions.preferHigher ?? false
        value.conditions.ageOlder = value.conditions.ageOlder ?? value.conditions.preferHigher ?? false
        _showAuthors = State(initialValue: !value.assignedUsers.isEmpty)
        _advancedGrouping = State(initialValue: value.conditions.match != (value.combine ?? .any))
        _rule = State(initialValue: value)
        _membershipBase = State(initialValue: value.assignedUsers)
        _karma = State(initialValue: String(value.conditions.karmaBelow ?? 100))
        _days = State(initialValue: String(value.conditions.youngerThanDays ?? 30))
        _useKarma = State(initialValue: value.conditions.karmaBelow != nil)
        _useAge = State(initialValue: value.conditions.youngerThanDays != nil)
        _useDate = State(initialValue: value.conditions.createdSince != nil)
        _date = State(initialValue: value.conditions.createdSince ?? Date())
    }
    private var value: FilterRule {
        var result = rule
        result.conditions.enabled = true
        result.conditions.karmaBelow = useKarma ? Int(karma) : nil
        result.conditions.youngerThanDays = useAge ? Int(days) : nil
        result.conditions.createdSince = useDate ? Calendar.current.startOfDay(for: date) : nil
        return result
    }
    private var canSave: Bool { valid && (!isNew || value.isActive || !value.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    private var valid: Bool { value.isValid && (!useKarma || Int(karma) != nil) && (!useAge || Int(days) != nil) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Filter name").font(.caption).foregroundStyle(.secondary)
                        #if os(macOS)
                        FilterNameField(text: $rule.name, placeholder: "Enter a filter name", active: true, accessibilityName: "Filter name")
                            .padding(8)
                            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 6))
                            .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                        #else
                        TextField("Enter a filter name", text: $rule.name)
                            .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                        #endif
                    }
                    Picker("Status", selection: $rule.enabled) {
                        Text("Active").tag(true)
                        Text("Paused").tag(false)
                    }.pickerStyle(.segmented)
                }
                Section("Match") {
                    Picker("Contributions", selection: Binding(get: { rule.scope ?? .both }, set: { rule.scope = $0 })) {
                        Text("Posts and comments").tag(FilterRule.Scope.both)
                        Text("Posts only").tag(FilterRule.Scope.posts)
                        Text("Comments only").tag(FilterRule.Scope.comments)
                    }
                    if conditionCount > 1 {
                        Picker("Match", selection: Binding(get: { rule.combine ?? .any }, set: {
                            rule.combine = $0
                            if !advancedGrouping { rule.conditions.match = $0 }
                        })) {
                            Text("Any of these conditions").tag(AccountFilters.Match.any)
                            Text("All of these conditions").tag(AccountFilters.Match.all)
                        }
                    }
                    if showAuthors {
                        VStack(alignment: .leading, spacing: 12) {
                            conditionHeader("Author is one of these users") { showAuthors = false; rule.assignedUsers = [] }
                            FilterMembersEditor(users: Binding(get: { rule.assignedUsers }, set: { rule.assignedUsers = $0 }), openNotes: { record = RecordDraft(username: $0) })
                        }
                    }
                    if useKarma || useAge || useDate {
                        VStack(alignment: .leading, spacing: 12) {
                            if advancedGrouping && accountConditionCount > 1 {
                                Text("Author’s account matches").font(.headline)
                                Picker("Within this account group", selection: $rule.conditions.match) {
                                    Text("Any of these account conditions").tag(AccountFilters.Match.any)
                                    Text("All of these account conditions").tag(AccountFilters.Match.all)
                                }
                            }
                            if useKarma {
                                conditionHeader("Author’s karma") { useKarma = false }
                                comparison("Comparison", binding: Binding(get: { rule.conditions.karmaHigher == true }, set: { rule.conditions.karmaHigher = $0 }), lower: "Below", higher: "At least")
                                TextField("Karma", text: $karma, prompt: Text("e.g. 500")).textFieldStyle(.roundedBorder)
                            }
                            if useDate {
                                conditionHeader("Author’s creation date") { useDate = false }
                                comparison("Comparison", binding: Binding(get: { rule.conditions.createdEarlier == true }, set: { rule.conditions.createdEarlier = $0 }), lower: "On or after", higher: "Before")
                                DatePicker("Date", selection: $date, displayedComponents: .date)
                            }
                            if useAge {
                                conditionHeader("Author’s account age") { useAge = false }
                                comparison("Comparison", binding: Binding(get: { rule.conditions.ageOlder == true }, set: { rule.conditions.ageOlder = $0 }), lower: "Younger than", higher: "At least")
                                TextField("Days", text: $days, prompt: Text("e.g. 30")).textFieldStyle(.roundedBorder)
                            }
                        }
                    }
                    if let content = rule.content {
                        VStack(alignment: .leading, spacing: 12) {
                            conditionHeader("Content matches") { rule.content = nil }
                            ContentPatternEditor(pattern: Binding(get: { rule.content ?? content }, set: { if rule.content != nil { rule.content = $0 } }))
                        }
                    }
                    Menu {
                        Button("Author") { showAuthors = true }.disabled(showAuthors)
                        Button("Author’s karma") { useKarma = true; alignGrouping() }.disabled(useKarma)
                        Button("Author’s creation date") { useDate = true; alignGrouping() }.disabled(useDate)
                        Button("Author’s account age") { useAge = true; alignGrouping() }.disabled(useAge)
                        Button("Content pattern") { rule.content = ContentPattern() }.disabled(rule.content != nil)
                    } label: { Label("Add condition…", systemImage: "plus") }
                    if accountConditionCount > 1 && (showAuthors || rule.content != nil) {
                        DisclosureGroup("Advanced grouping") {
                            Toggle("Group account conditions separately", isOn: $advancedGrouping)
                                .onChange(of: advancedGrouping) { _, enabled in if !enabled { alignGrouping() } }
                        }
                    }
                    Text(automaticSummary).font(.callout).foregroundStyle(.secondary)
                }
                Section("Effect") {
                    HStack {
                        Text("Action")
                        Spacer()
                        FilterEffectPicker(rule: $rule)
                    }
                    if rule.effect == .block {
                        VStack(alignment: .leading, spacing: 8) {
                            Picker("When blocking", selection: Binding(get: { rule.includesReplies }, set: { rule.hideReplies = $0 })) {
                                Text("Hide matching contribution only").tag(false)
                                Text("Hide contribution and replies").tag(true)
                            }
                            #if os(macOS)
                            .pickerStyle(.radioGroup)
                            #endif
                            Text(rule.includesReplies
                                 ? "A hidden post hides its entire discussion. A hidden comment hides every reply beneath it."
                                 : "Hide the matched post or comment. Its discussion and replies remain available.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    DisclosureGroup("Direct contributions · \((rule.itemIDs ?? []).count)") {
                        Text("These posts and comments bypass the conditions above. The selected scope still applies. Direct assignments win over automatic matches; filter order breaks ties.")
                            .font(.caption).foregroundStyle(.secondary)
                        DirectContributionsEditor(ids: Binding(get: { rule.itemIDs ?? [] }, set: { rule.itemIDs = $0 }))
                    }
                }
                Text(!valid ? "Correct the highlighted fields. Your last valid settings remain active." : saveFailed ? "Could not save. Your edits are still here." : isNew ? "Draft · Saved only when you click Create" : "Saved automatically")
                    .font(.caption).foregroundStyle(!valid || saveFailed ? Color.red : Color.secondary)
                if store.archive.rules.contains(where: { $0.id == id }) {
                    Button("Delete filter", role: .destructive) { if store.saveRules(store.archive.rules.filter { $0.id != id }) { dismiss() } }
                }
            }.formStyle(.grouped).toggleStyle(.switch)
            .navigationTitle(isNew ? "New filter" : "Edit filter")
            .toolbar {
                if isNew {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(isNew ? "Create" : "Done") {
                        saveChanges()
                        if !saveFailed { dismiss() }
                    }.disabled(!canSave).keyboardShortcut(.defaultAction)
                }
            }
            .onChange(of: value) { _, value in
                saveTask?.cancel()
                guard !isNew, valid else { return }
                saveTask = Task { @MainActor in
                    do { try await Task.sleep(for: .seconds(1)) } catch { return }
                    guard valid, store.archive.rules.contains(where: { $0.id == id }) else { return }
                    saveChanges()
                }
            }
            .onDisappear {
                saveTask?.cancel()
                if !isNew, valid, store.archive.rules.contains(where: { $0.id == id }) {
                    saveChanges()
                }
            }
            .onChange(of: store.archive.rules) { _, rules in
                if !isNew, let stored = rules.first(where: { $0.id == id }) {
                    rule.assignedUsers = RuleListEdits.mergingMembers(base: membershipBase,
                        edited: rule.assignedUsers, stored: stored.assignedUsers)
                    membershipBase = stored.assignedUsers
                }
            }
            .sheet(item: $record) { RecordEditor(store: store, draft: $0) }
        }
        #if os(macOS)
        .frame(width: 640, height: 720)
        #endif
    }
    private func saveChanges() {
        var updated = value
        // Rebase at commit too: the store may publish before SwiftUI delivers onChange.
        if let stored = store.archive.rules.first(where: { $0.id == id }) {
            updated.assignedUsers = RuleListEdits.mergingMembers(base: membershipBase,
                edited: updated.assignedUsers, stored: stored.assignedUsers)
        }
        saveFailed = !store.saveRules(RuleListEdits.updating(updated, in: store.archive.rules))
        if !saveFailed {
            membershipBase = updated.assignedUsers
            rule.assignedUsers = updated.assignedUsers
        }
    }
    private var accountConditionCount: Int { [useKarma, useAge, useDate].filter { $0 }.count }
    private var conditionCount: Int { accountConditionCount + (showAuthors ? 1 : 0) + (rule.content == nil ? 0 : 1) }
    private func alignGrouping() { if !advancedGrouping { rule.conditions.match = rule.combine ?? .any } }
    private func conditionHeader(_ title: String, remove: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button(action: remove) { Image(systemName: "minus.circle") }
                .buttonStyle(ControlSurfaceStyle()).accessibilityLabel("Remove " + title)
        }
    }
    private var automaticSummary: String {
        var clauses: [String] = []
        if !rule.assignedUsers.isEmpty { clauses.append("the author is " + rule.assignedUsers.sorted().joined(separator: " or ")) }
        var account: [String] = []
        if useKarma { account.append("the author’s karma is " + (rule.conditions.karmaHigher == true ? "at least " : "below ") + karma) }
        if useAge { account.append("the account is " + (rule.conditions.ageOlder == true ? "at least " : "younger than ") + days + " days old") }
        if useDate { account.append("the account was created " + (rule.conditions.createdEarlier == true ? "before " : "on or after ") + date.formatted(date: .abbreviated, time: .omitted)) }
        if !account.isEmpty {
            let group = account.joined(separator: rule.conditions.match == .all ? " and " : " or ")
            clauses.append(advancedGrouping && account.count > 1 ? "(" + group + ")" : group)
        }
        if let content = rule.content {
            let field = content.field == .body ? "body text" : "post " + content.field.rawValue
            clauses.append("the " + field + (content.mode == .regex ? " matches the pattern “" : " contains “") + content.pattern + "”")
        }
        guard !clauses.isEmpty else { return "Add a condition to match automatically, or assign individual contributions below." }
        let action: String
        switch rule.effect { case .block: action = "Hide"; case .fade: action = "Fade"; case .highlight: action = "Highlight"; case .allow: action = "Show normally" }
        let scope = rule.scope == .posts ? "posts" : rule.scope == .comments ? "comments" : "posts and comments"
        return action + " " + scope + " when " + clauses.joined(separator: rule.combine == .all ? " and " : " or ") + "."
    }
    private func comparison(_ title: String, binding: Binding<Bool>, lower: String, higher: String) -> some View {
        Picker(title, selection: binding) { Text(lower).tag(false); Text(higher).tag(true) }
    }
}
