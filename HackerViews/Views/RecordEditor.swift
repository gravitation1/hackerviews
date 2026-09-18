import SwiftUI

struct RecordEditor: View {
    @ObservedObject var store: RecordStore
    let draft: RecordDraft
    @Environment(\.dismiss) private var dismiss
    @State private var username: String
    @State private var note: String
    @State private var citations: [Citation]
    @State private var addingCitation = false
    @State private var focusedReferenceID: UUID?
    @State private var savedUsername: String?
    @State private var saveFailed = false
    @State private var started = false
    @State private var effectiveMatch: AccountRuleMatch?
    @State private var contributionSummary = "Checking contribution effect…"
    @State private var accountService = HNService.shared
    @State private var noteSaveTask: Task<Void, Never>?
    @FocusState private var editingUsername: Bool

    init(store: RecordStore, draft: RecordDraft) {
        self.store = store; self.draft = draft
        let existing = store.current(draft.username)
        _username = State(initialValue: draft.username)
        _savedUsername = State(initialValue: draft.username.isEmpty ? nil : draft.username)
        _note = State(initialValue: existing?.note ?? "")
        _citations = State(initialValue: existing?.citations ?? [])
    }

    var body: some View {
        if let source = draft.citation, let id = contributionID, !draft.filtersOnly {
            FlagContributionView(store: store, username: draft.username, source: source, itemID: id)
        } else {
            legacyEditor
        }
    }

    private var legacyEditor: some View {
        NavigationStack {
            Form {
                if savedUsername == nil {
                    TextField("HN username", text: $username).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never)
                        #endif
                        .disabled(savedUsername != nil)
                        .focused($editingUsername)
                        .onSubmit { saveChanges() }
                }
                if let itemID = contributionID {
                    Section("This contribution") {
                        Text(contributionSummary).font(.headline)
                        Text("Assignments here apply to this post or comment, not every contribution by its author.").font(.caption)
                        ForEach(store.archive.rules.filter { $0.itemIDs?.contains(itemID) == true }) { filter in
                            HStack {
                                Text(filter.name + " · " + filter.effectLabel)
                                Spacer()
                                Button("Remove") { assignContribution(itemID, filter: filter, assigned: false) }
                            }
                        }
                        Menu("Assign contribution to filter…") {
                            ForEach(store.archive.rules.filter { $0.itemIDs?.contains(itemID) != true }) { filter in
                                Button(filter.name + " · " + filter.effectLabel) { assignContribution(itemID, filter: filter, assigned: true) }
                            }
                        }
                        Text("Direct assignments take priority over user and pattern matches. The filter’s post/comment scope still applies.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let name = savedUsername {
                    memberships(name)
                }
                if !draft.filtersOnly {
                Section("Notes") {
                    AccountNotesEditor(text: $note)
                        .frame(height: 96)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    if let source = draft.citation,
                       !citations.contains(where: { $0.url == source.url && $0.excerpt == source.excerpt }) {
                        Button {
                            var saved = source
                            saved.savedIntentionally = true
                            focusedReferenceID = saved.id
                            citations.append(saved)
                        } label: {
                            Label("Add note about this " + (source.excerpt.isEmpty ? "page" : "contribution"), systemImage: "square.and.pencil")
                        }
                    }
                    if citations.isEmpty { Text("No saved references.").foregroundStyle(.secondary) }
                    ForEach(citations) { citation in
                        SavedReferenceRow(citation: referenceBinding(in: $citations, reference: citation), focusOnAppear: focusedReferenceID == citation.id) {
                            citations.removeAll { $0.id == citation.id }
                        }
                    }
                    Button { addingCitation = true } label: { Label("Add reference…", systemImage: "plus") }
                } header: { Text("Saved references · \(citations.count)") }
                Section {
                    Text(saveFailed ? "Could not save. Your edits are still here; try Done again." : "Private · Saved automatically")
                        .font(.caption).foregroundStyle(saveFailed ? Color.red : Color.secondary)
                    if let name = savedUsername, store.current(name) != nil {
                        DisclosureGroup("Edit history") {
                            ForEach(store.archive.history(for: name)) { revision in
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(revision.modifiedAt.formatted()).font(.caption).foregroundStyle(.secondary)
                                    Text(revision.note.isEmpty ? "No notes" : revision.note)
                                    Text("\(revision.citations.count) references")
                                        .font(.caption).foregroundStyle(.secondary)
                                    if revision.id != store.current(name)?.id {
                                        Button("Restore this version") {
                                            note = revision.note; citations = revision.citations
                                            saveChanges()
                                        }
                                    }
                                }.padding(.vertical, 5)
                            }
                        }
                    }
                }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(draft.filtersOnly ? "Filters for " + username : (username.isEmpty ? "New user record" : username))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveChanges(); if !saveFailed { dismiss() } }
                        .keyboardShortcut(.defaultAction)
                }
            }
            .sheet(isPresented: $addingCitation) {
                CitationEditor(author: username) { citation in
                    if let index = citations.firstIndex(where: { $0.id == citation.id }) { citations[index] = citation }
                    else { citations.append(citation) }
                }
            }
            .toggleStyle(.switch)
            .onChange(of: note) { _, _ in
                noteSaveTask?.cancel()
                noteSaveTask = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    saveChanges()
                }
            }
            .onDisappear { noteSaveTask?.cancel(); saveChanges() }
            .onChange(of: citations) { _, _ in
                noteSaveTask?.cancel()
                noteSaveTask = Task { @MainActor in
                    do { try await Task.sleep(for: .milliseconds(500)) } catch { return }
                    saveChanges()
                }
            }
            .onChange(of: editingUsername) { _, editing in if !editing { saveChanges() } }
            .onAppear {
                guard !started else { return }
                started = true

            }
        }
        #if os(macOS)
        .frame(width: 680, height: draft.filtersOnly ? 460 : 760)
        #endif
    }
    private var contributionID: Int? {
        guard let link = draft.citation?.url, let url = URLComponents(string: link),
              url.host == "news.ycombinator.com", url.path == "/item",
              let raw = url.queryItems?.first(where: { $0.name == "id" })?.value,
              let id = Int(raw), id > 0 else { return nil }
        return id
    }
    private func assignContribution(_ id: Int, filter: FilterRule, assigned: Bool) {
        var updated = filter
        var ids = updated.itemIDs ?? []
        if assigned { ids.insert(id) } else { ids.remove(id) }
        updated.itemIDs = ids
        _ = store.saveRules(RuleListEdits.updating(updated, in: store.archive.rules))
    }

    private func memberships(_ name: String) -> some View {
        Group {
            Section(contributionID == nil ? "Applied effect" : "Author’s account filters") {
                if let match = effectiveMatch {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(match.label).font(.headline)
                        if let filterName = match.ruleName {
                            if match.effect == "unresolved" {
                                Text("Waiting to verify \(filterName) before deciding the effect.")
                            } else if let conditions = match.matchedConditions {
                                Text("Automatically matched \(filterName)")
                                Text("Because: " + conditionSummary(conditions)).font(.callout).foregroundStyle(.secondary)
                            } else {
                                Text("From your direct assignment to \(filterName)")
                            }
                        } else {
                            Text(match.effect == "varies" ? "Post/comment scope, content patterns, and direct assignments are evaluated for each contribution." : "No active filter matches this account.").foregroundStyle(.secondary)
                        }
                        if match.contributionCaveat {
                            Text("Content, scope, and per-item rules may change the effect on individual contributions.").font(.caption).foregroundStyle(.secondary)
                        }
                    }.padding(.vertical, 4)
                } else { Text("Checking applied effect…").foregroundStyle(.secondary) }
            }
            Section {
                let assigned = store.archive.rules.filter { $0.assignedUsers.contains(name) }
                if assigned.isEmpty {
                    Text("No filters assigned directly.").foregroundStyle(.secondary)
                }
                ForEach(assigned) { filter in
                    HStack {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(filter.name.isEmpty ? "Unnamed filter" : filter.name).font(.headline)
                            Text(filter.effectLabel).font(.callout)
                            Text(assignmentStatus(filter)).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Remove") { setMembership(name, filter: filter, assigned: false) }
                            .buttonStyle(ControlSurfaceStyle())
                            .help("Remove this assignment; keep notes and citations")
                    }.padding(.vertical, 4)
                }
                Menu("Assign to filter…") {
                    ForEach(store.archive.rules.filter { !$0.assignedUsers.contains(name) }) { filter in
                        Button(assignmentChoice(filter)) { setMembership(name, filter: filter, assigned: true) }
                    }
                }.disabled(store.archive.rules.allSatisfy { $0.assignedUsers.contains(name) })
            } header: { Text("Explicit assignments") } footer: {
                Text("First active match wins. Assignments leave your notes unchanged.")
            }
        }
        .task(id: store.archive.filterRevisions?.max { $0.modifiedAt < $1.modifiedAt }?.id) {
            effectiveMatch = nil
            if let id = contributionID {
                let result = await accountService.decisions(ids: [id], rules: store.archive.rules)
                if !Task.isCancelled {
                    let effect = result.effects[String(id)] ?? "unresolved"
                    let label: String
                    if effect.hasPrefix("highlight:") { label = "Highlighted" }
                    else if effect.hasPrefix("fade:") { label = "Faded " + effect.dropFirst(5) + "%" }
                    else if effect == "hidden-item" || effect == "blocked" { label = "Blocked" }
                    else if effect == "visible" { label = "Shown normally" }
                    else { label = "Couldn’t verify effect" }
                    contributionSummary = label + (result.labels[String(id)].map { " · " + $0 } ?? "")
                }
            }
            let result = await accountService.accountMatch(name, rules: store.archive.rules)
            if !Task.isCancelled { effectiveMatch = result }
        }
    }

    private func conditionSummary(_ conditions: AccountFilters) -> String {
        var rule = FilterRule(); rule.conditions = conditions
        return rule.summary
    }

    private func assignmentStatus(_ filter: FilterRule) -> String {
        guard filter.enabled else { return "Paused" }
        guard let match = effectiveMatch else { return "Checking precedence…" }
        guard let index = store.archive.rules.firstIndex(where: { $0.id == filter.id }), let priority = match.priority else {
            return "Checking precedence…"
        }
        if match.effect == "unresolved" { return "Waiting for verification of " + (match.ruleName ?? "an earlier filter") }
        if index + 1 == priority { return "Determines the applied effect" }
        return "Overridden by " + (match.ruleName ?? "an earlier filter")
    }

    private func assignmentChoice(_ filter: FilterRule) -> String {
        let title = (filter.name.isEmpty ? "Unnamed filter" : filter.name) + " · " + filter.effectLabel
        guard filter.enabled else { return title + " · Paused" }
        guard let match = effectiveMatch, let priority = match.priority,
              let index = store.archive.rules.firstIndex(where: { $0.id == filter.id }) else { return title }
        if index + 1 > priority { return title + " · After " + (match.ruleName ?? "current match") }
        return title
    }

    private func setMembership(_ name: String, filter: FilterRule, assigned: Bool) {
        var rules = store.archive.rules
        guard let index = rules.firstIndex(where: { $0.id == filter.id }) else { return }
        if assigned { rules[index].assignedUsers.insert(name) }
        else { rules[index].assignedUsers.remove(name) }
        store.saveRules(rules)
    }

    private func saveChanges() {
        guard !draft.filtersOnly else { return }
        let name = savedUsername ?? username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RecordArchive.validUsername(name) else { return }
        let current = store.current(name)
        if savedUsername == nil, let current {
            savedUsername = name
            note = current.note; citations = current.citations
            return
        }
        if current == nil && note.isEmpty && citations.isEmpty {
            savedUsername = name; saveFailed = false; return
        }
        guard current == nil || current?.note != note || current?.citations != citations else { saveFailed = false; return }
        if store.save(username: name, blocked: current?.isBlocked ?? false, note: note, citations: citations, preferred: current?.isPreferred ?? false) {
            savedUsername = name; saveFailed = false
        } else { saveFailed = true }
    }

}

/// Text fields can retain their bindings after a row is removed or history is restored.
/// Resolve identity on every access; a departing row may read its snapshot, but must
/// never write into another reference or reinsert a deleted one.
func referenceBinding(in references: Binding<[Citation]>, reference: Citation) -> Binding<Citation> {
    Binding(
        get: { references.wrappedValue.first { $0.id == reference.id } ?? reference },
        set: { updated in
            var current = references.wrappedValue
            guard updated.id == reference.id,
                  let index = current.firstIndex(where: { $0.id == reference.id }) else { return }
            current[index] = updated
            references.wrappedValue = current
        }
    )
}

private struct SavedReferenceRow: View {
    @Binding var citation: Citation
    var focusOnAppear = false
    let remove: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                if let url = URL(string: citation.url) {
                    Link(citation.context.isEmpty ? citation.url : citation.context, destination: url)
                        .lineLimit(2)
                }
                Spacer()
                Button("Remove", action: remove).buttonStyle(ControlSurfaceStyle())
                    .foregroundStyle(.secondary)
                    .help("Remove this saved reference")
            }
            Text((URL(string: citation.url)?.host ?? citation.url) + " · " + citation.capturedAt.formatted(date: .abbreviated, time: .omitted))
                .font(.caption).foregroundStyle(.secondary)
            AccountNotesEditor(text: $citation.annotation, placeholder: "Add a note about this reference…", focusOnAppear: focusOnAppear)
                .frame(height: 80)
                .frame(maxWidth: .infinity, alignment: .leading)
            DisclosureGroup("Saved excerpt") {
                VStack(alignment: .leading, spacing: 8) {
                    Text(citation.url).font(.caption).textSelection(.enabled)
                    if !citation.excerpt.isEmpty {
                        Text(citation.excerpt).font(.callout).textSelection(.enabled)
                    }
                }.padding(.top, 4)
            }.font(.caption)
        }.padding(.vertical, 4)
    }
}

private struct CitationEditor: View {
    let author: String
    let save: (Citation) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var url = ""
    @State private var context = ""
    @State private var excerpt = ""
    @State private var citationID = UUID()
    @State private var capturedAt = Date()
    var body: some View {
        NavigationStack {
            Form {
                Section("Source") {
                    TextField("https://…", text: $url).autocorrectionDisabled()
                        #if os(iOS)
                        .textInputAutocapitalization(.never).keyboardType(.URL)
                        #endif
                    TextField("Title or context", text: $context)
                }
                Section("Saved excerpt") { TextEditor(text: $excerpt).frame(minHeight: 90) }
                Text("Optional: paste text you want to keep with this reference.").font(.caption).foregroundStyle(.secondary)
            }.formStyle(.grouped)
            .navigationTitle("Add reference")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { saveChanges(); dismiss() }.keyboardShortcut(.defaultAction)
                }
            }
            .onChange(of: url) { _, _ in saveChanges() }
            .onChange(of: context) { _, _ in saveChanges() }
            .onChange(of: excerpt) { _, _ in saveChanges() }
            .onDisappear { saveChanges() }
        }
        #if os(macOS)
        .frame(width: 560, height: 480)
        #endif
    }

    private func saveChanges() {
        let link = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard RecordArchive.validCitationURL(link) else { return }
        var citation = Citation(url: link, author: author, excerpt: excerpt, context: context)
        citation.id = citationID; citation.capturedAt = capturedAt; citation.savedIntentionally = true
        save(citation)
    }
}

/// A contribution is evidence for a user flag by default. All edits remain local
/// until the single archive transaction succeeds.
private struct FlagContributionView: View {
    @ObservedObject var store: RecordStore
    let username: String
    let source: Citation
    let itemID: Int
    @Environment(\.dismiss) private var dismiss
    @State private var userTarget = true
    @State private var filterID = ""
    @State private var annotation = ""
    @State private var attached = true
    @State private var newFilter: FilterRule = {
        var rule = FilterRule()
        rule.effect = .highlight
        return rule
    }()
    private let createID = "create-new-filter"
    @State private var preview = ""
    @State private var failed = false
    @State private var service = HNService.shared

    private var creating: Bool { filterID == createID }
    private var selected: FilterRule? { creating ? newFilter : store.archive.rules.first { $0.id == filterID } }
    private var canSave: Bool {
        if creating { return !newFilter.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && newFilter.isValid }
        return (filterID.isEmpty || selected != nil) && (!filterID.isEmpty || attached || !annotation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    private var summary: String {
        var parts: [String] = []
        if let selected {
            parts.append((creating ? "Create “" + selected.name + "” and add " : "Add ") + (userTarget ? username : "this contribution") + (creating ? "." : " to “" + selected.name + "”."))
        }
        if attached { parts.append("Save the attached contribution" + (annotation.isEmpty ? "." : " with your note.")) }
        else if !annotation.isEmpty { parts.append("Save your note on the user’s profile.") }
        return parts.isEmpty ? "Choose a filter, write a note, or attach the contribution." : parts.joined(separator: " ")
    }
    private var proposedRules: [FilterRule] {
        var rules = store.archive.rules
        if creating {
            var rule = newFilter
            rule.name = rule.name.trimmingCharacters(in: .whitespacesAndNewlines)
            rules = RuleListEdits.updating(rule, in: rules)
        }
        if let index = rules.firstIndex(where: { $0.id == (creating ? newFilter.id : filterID) }) {
            if userTarget { rules[index].assignedUsers.insert(username) }
            else {
                var ids = rules[index].itemIDs ?? []
                ids.insert(itemID)
                rules[index].itemIDs = ids
            }
        }
        return rules
    }
    private var previewKey: String {
        String(userTarget) + filterID + String(describing: newFilter) + String(describing: store.archive.filterRevisions)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Apply to", selection: $userTarget) {
                        Text("This user").tag(true)
                        Text("Only this contribution").tag(false)
                    }.pickerStyle(.segmented)
                    Picker(userTarget ? "Add \(username) to filter" : "Add contribution to filter", selection: $filterID) {
                        Text("No filter · Note only").tag("")
                        Text("Create filter…").tag(createID)
                        ForEach(store.archive.rules) { rule in
                            Text(rule.name + " · " + rule.effectLabel + (rule.enabled ? "" : " · Paused")).tag(rule.id)
                        }
                    }
                    if creating {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("New filter").font(.headline)
                            TextField("Filter name", text: $newFilter.name)
                                .textFieldStyle(.roundedBorder).labelsHidden()
                                .accessibilityLabel("New filter name")
                            HStack { Text("Effect"); Spacer(); FilterEffectPicker(rule: $newFilter) }
                            Text("Added at the top of your filter list. New filters here start with Highlight; choose Block to hide matching contributions. You can change priority and conditions in Filters.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    if let selected {
                        Text(userTarget
                             ? "Adds \(username) to \(selected.name). The filter’s scope and other conditions still apply."
                             : "Applies to this contribution only.")
                            .font(.callout).foregroundStyle(.secondary)
                        Text(preview.isEmpty ? "Checking resulting effect…" : preview)
                            .font(.callout)
                    }
                } header: { Text(userTarget ? "Flag \(username)" : "Flag this contribution") }
                Section("Attached contribution") {
                    if attached {
                        if !source.excerpt.isEmpty { Text(source.excerpt).textSelection(.enabled) }
                        HStack {
                            if let url = URL(string: source.url) {
                                Link("View original contribution", destination: url).font(.callout)
                            }
                            Spacer()
                            Button("Remove attachment") { attached = false }
                                .buttonStyle(ControlSurfaceStyle())
                        }
                    } else {
                        Button("Attach this contribution") { attached = true }
                    }
                }
                Section("Your note") {
                    AccountNotesEditor(text: $annotation, placeholder: "Add an optional note…")
                        .frame(height: 100)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                Section {
                    Text(summary).font(.callout)
                    Text(failed ? "Could not save. Your draft is still here. Try again." : "Private · Nothing is saved until you click Save.")
                        .font(.caption).foregroundStyle(failed ? Color.red : Color.secondary)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(username)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                }
            }
            .task(id: previewKey) {
                preview = ""
                guard let selected, !creating || canSave else { return }
                do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
                let result = await service.decisions(ids: [itemID], rules: proposedRules)
                guard !Task.isCancelled else { return }
                let effect = result.effects[String(itemID)] ?? "unresolved"
                let label = result.labels[String(itemID)]
                let outcome: String
                if effect == "blocked" || effect == "hidden-item" { outcome = "Blocked" }
                else if effect.hasPrefix("highlight:") { outcome = "Highlighted" }
                else if effect.hasPrefix("fade:") { outcome = "Faded" }
                else if effect == "visible" { outcome = "Shown normally" }
                else { outcome = "Could not verify the resulting effect" }
                preview = "This contribution: " + outcome + (label.map { " · " + $0 } ?? "")
                if !selected.enabled { preview += ". Selected filter is paused." }
                else if let label, !label.hasPrefix(selected.name) {
                    preview += ". Another matching filter or blocked ancestor takes priority."
                }
            }
        }
        #if os(macOS)
        .frame(width: 640, height: 640)
        #endif
    }

    private func save() {
        guard canSave else { failed = true; return }
        let current = store.current(username)
        var references = current?.citations ?? []
        var personalNote = current?.note ?? ""
        if attached {
        var reference = source
        reference.savedIntentionally = true
        reference.annotation = annotation
        if let index = references.firstIndex(where: { $0.url == source.url && $0.excerpt == source.excerpt }) {
            reference = references[index]
            reference.savedIntentionally = true
            if !annotation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                reference.annotation = reference.annotation.isEmpty ? annotation : reference.annotation + "\n\n" + annotation
            }
            references[index] = reference
        } else { references.append(reference) }
        } else if !annotation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            personalNote += (personalNote.isEmpty ? "" : "\n\n") + annotation
        }
        if !attached && annotation.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if store.saveRules(proposedRules) { dismiss() } else { failed = true }
            return
        }
        if store.save(username: username, blocked: current?.isBlocked ?? false,
                      note: personalNote, citations: references,
                      preferred: current?.isPreferred ?? false, rules: proposedRules) {
            dismiss()
        } else { failed = true }
    }
}
