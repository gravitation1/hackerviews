import SwiftUI

struct FilterMembersEditor: View {
    @Binding var users: Set<String>
    var openNotes: (String) -> Void
    @State private var entry = ""
    private var name: String { entry.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                TextField("Enter a username…", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .multilineTextAlignment(.leading)
                    .accessibilityLabel("HN username")
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                    .onSubmit { add() }
                Button("Assign") { add() }
                    .disabled(!RecordArchive.validUsername(name) || users.contains(name))
            }
            if users.isEmpty { Text("No users assigned").foregroundStyle(.secondary).font(.caption) }
            ForEach(users.sorted(), id: \.self) { user in
                HStack {
                    Button(user) { openNotes(user) }.buttonStyle(ControlSurfaceStyle())
                        .help("Notes and citations for \(user)")
                    Spacer()
                    Button { users.remove(user) } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(ControlSurfaceStyle()).accessibilityLabel("Remove \(user) from this filter")
                }
            }
        }
    }
    private func add() {
        guard RecordArchive.validUsername(name), !users.contains(name) else { return }
        users.insert(name); entry = ""
    }
}
