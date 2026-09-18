import SwiftUI

struct DirectContributionsEditor: View {
    @Binding var ids: Set<Int>
    @State private var entry = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Paste a Hacker News post or comment link", text: $entry)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { assign() }
                Button("Assign") { assign() }.disabled(HNItem.assignmentID(entry) == nil)
            }
            if !entry.isEmpty && HNItem.assignmentID(entry) == nil {
                Text("Use a news.ycombinator.com/item?id=… link or an item number.").font(.caption).foregroundStyle(.red)
            }
            ForEach(ids.sorted(), id: \.self) { id in
                ContributionPreview(id: id) { ids.remove(id) }
            }
        }.padding(.top, 8)
    }
    private func assign() {
        guard let id = HNItem.assignmentID(entry) else { return }
        ids.insert(id); entry = ""
    }
}

private struct ContributionPreview: View {
    let id: Int
    let remove: () -> Void
    @State private var title = "Loading contribution…"
    @State private var detail = ""
    @State private var service = HNService.shared
    var body: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Link(title, destination: URL(string: "https://news.ycombinator.com/item?id=\(id)")!)
                    .lineLimit(3)
                Text(detail.isEmpty ? "news.ycombinator.com/item?id=\(id)" : detail)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remove", action: remove).buttonStyle(ControlSurfaceStyle())
        }
        .task(id: id) {
            guard let item = try? await service.item(id) else { title = "Contribution unavailable"; return }
            let text = ContentPattern.readable(item.type == "comment" ? (item.text ?? "") : (item.title ?? ""))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            title = text.isEmpty ? "Deleted or unavailable contribution" : text
            detail = (item.type == "comment" ? "Comment" : "Post") + (item.by.map { " by " + $0 } ?? "")
        }
    }
}
