import SwiftUI

struct FilterEditor: View {
    @ObservedObject var store: RecordStore
    let id: String
    @Environment(\.dismiss) private var dismiss
    @State private var rule: FilterRule
    @State private var karma: String
    @State private var days: String
    @State private var useKarma: Bool
    @State private var useAge: Bool
    @State private var useDate: Bool
    @State private var date: Date
    @State private var record: RecordDraft?
    init(store: RecordStore, id: String) {
        self.store = store; self.id = id
        var value = store.archive.rules.first { $0.id == id } ?? FilterRule()
        value.id = id
        value.conditions.karmaHigher = value.conditions.karmaHigher ?? value.conditions.preferHigher ?? false
        value.conditions.createdEarlier = value.conditions.createdEarlier ?? value.conditions.preferHigher ?? false
        value.conditions.ageOlder = value.conditions.ageOlder ?? value.conditions.preferHigher ?? false
        _rule = State(initialValue: value)
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
    private var valid: Bool { value.isValid && (!useKarma || Int(karma) != nil) && (!useAge || Int(days) != nil) }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $rule.name)
                    Toggle("Enabled", isOn: $rule.enabled)
                    HStack {
                        Text("Effect")
                        Spacer()
                        FilterEffectPicker(rule: $rule)
                    }
                }
                Section("Assigned users") {
                    FilterMembersEditor(users: Binding(get: { rule.assignedUsers }, set: { rule.assignedUsers = $0 }), openNotes: { record = RecordDraft(username: $0) })
                }
                Section("Account conditions") {
                    Text("Matches assigned users OR these conditions. Leave both empty to match nobody.")
                        .font(.caption).foregroundStyle(.secondary)
                        Picker("Combine", selection: $rule.conditions.match) {
                            Text("Any condition (OR)").tag(AccountFilters.Match.any)
                            Text("All conditions (AND)").tag(AccountFilters.Match.all)
                        }
                        Toggle("Karma", isOn: $useKarma)
                        if useKarma {
                            comparison("Karma comparison", binding: Binding(get: { rule.conditions.karmaHigher == true }, set: { rule.conditions.karmaHigher = $0 }), lower: "Below", higher: "At least")
                            TextField("Karma threshold", text: $karma)
                        }
                        Toggle("Creation date", isOn: $useDate)
                        if useDate {
                            comparison("Date comparison", binding: Binding(get: { rule.conditions.createdEarlier == true }, set: { rule.conditions.createdEarlier = $0 }), lower: "On or after", higher: "Before")
                            DatePicker("Date", selection: $date, displayedComponents: .date)
                        }
                        Toggle("Account age", isOn: $useAge)
                        if useAge {
                            comparison("Age comparison", binding: Binding(get: { rule.conditions.ageOlder == true }, set: { rule.conditions.ageOlder = $0 }), lower: "Younger than", higher: "At least")
                            TextField("Age in days", text: $days)
                        }
                }
                Text(valid ? "Changes apply immediately. First matching filter wins. An empty filter matches nobody." : "Enter a valid username or whole-number thresholds. Your last valid settings remain active.")
                    .font(.caption).foregroundStyle(valid ? Color.secondary : Color.red)
                if store.archive.rules.contains(where: { $0.id == id }) {
                    Button("Delete filter", role: .destructive) { if store.saveRules(store.archive.rules.filter { $0.id != id }) { dismiss() } }
                } else {
                    Text("No filter created yet. Give it a name, assign a user, or choose a condition to create it. Closing this empty editor creates nothing.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.formStyle(.grouped).toggleStyle(.switch)
            .navigationTitle("Filter")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: value) { _, value in
                guard valid else { return }
                store.saveRules(RuleListEdits.updating(value, in: store.archive.rules))
            }
            .onChange(of: store.archive.rules) { _, rules in
                if let stored = rules.first(where: { $0.id == id }) {
                    rule.assignedUsers = stored.assignedUsers
                }
            }
            .sheet(item: $record) { RecordEditor(store: store, draft: $0) }
        }
        #if os(macOS)
        .frame(width: 640, height: 720)
        #endif
    }
    private func comparison(_ title: String, binding: Binding<Bool>, lower: String, higher: String) -> some View {
        Picker(title, selection: binding) { Text(lower).tag(false); Text(higher).tag(true) }
    }
}
