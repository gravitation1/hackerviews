import SwiftUI

struct SavedNotesView: View {
    @ObservedObject var store: RecordStore
    let openProfile: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    private var people: [PersonRevision] {
        store.people.filter { $0.hasSavedNotes && $0.matchesSavedNotesSearch(query) }
    }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search users, notes, and references", text: $query)
                        .textFieldStyle(.roundedBorder).multilineTextAlignment(.leading)
                        .accessibilityLabel("Search saved notes")
                }.padding()
                if people.isEmpty {
                    ContentUnavailableView(query.isEmpty ? "No saved notes yet" : "No matching notes",
                        systemImage: "note.text",
                        description: Text(query.isEmpty ? "Notes and references you save on profiles and contributions will appear here." : "Try another username or phrase."))
                } else {
                    List(people) { person in
                        Button { openProfile(person.username) } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 6) {
                                    Text(person.username).font(.headline)
                                    Text(person.savedNotePreview).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                    Text("\(person.citations.count) saved \(person.citations.count == 1 ? "reference" : "references")")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "arrow.up.right").foregroundStyle(.secondary)
                            }.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle()).padding(.vertical, 6)
                        }.buttonStyle(ControlSurfaceStyle())
                            .help("Open \(person.username)’s profile and notes")
                            .accessibilityLabel("Open \(person.username)’s profile. \(person.savedNotePreview). \(person.citations.count) saved references.")
                    }
                }
            }
            .navigationTitle("Saved notes")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }.keyboardShortcut(.cancelAction)
                }
            }
        }
        #if os(macOS)
        .frame(width: 560, height: 520)
        #endif
    }
}
