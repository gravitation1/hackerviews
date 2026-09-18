import SwiftUI

struct ContentPatternEditor: View {
    @Binding var pattern: ContentPattern
    @State private var sample = ""
    @State private var result = "Enter sample text to test the pattern."
    @State private var marked = AttributedString("")
    var body: some View {
        Group {
            Picker("Field", selection: $pattern.field) {
                Text("Post title").tag(ContentPattern.Field.title)
                Text("Post URL").tag(ContentPattern.Field.url)
                Text("Post domain").tag(ContentPattern.Field.domain)
                Text("Body text").tag(ContentPattern.Field.body)
            }
            Picker("Match", selection: $pattern.mode) {
                Text("Contains text").tag(ContentPattern.Mode.contains)
                Text("Regular expression").tag(ContentPattern.Mode.regex)
            }
            TextField("Pattern", text: $pattern.pattern).multilineTextAlignment(.leading)
            Toggle("Ignore case", isOn: $pattern.ignoreCase)
            if let error = pattern.error { Text(error).foregroundStyle(.red) }
            DisclosureGroup("Test pattern") {
                VStack(alignment: .leading, spacing: 10) {
                    AccountNotesEditor(text: $sample, placeholder: "Sample text")
                        .frame(height: 80)
                    Text(result).font(.caption)
                    if !sample.isEmpty { Text(marked).textSelection(.enabled) }
                    Text("Body patterns match readable text. Regex uses ICU syntax; slow matches are stopped and reported as unverified.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .task(id: pattern.pattern + pattern.mode.rawValue + String(pattern.ignoreCase) + sample) {
            let input = sample, current = pattern
            let tested = await Task.detached { current.test(input) }.value
            guard !Task.isCancelled else { return }
            result = tested.decision == .blocked ? "Matches (first match highlighted)" : tested.decision == .visible ? "No match" : "Invalid pattern, input too long, or matching time limit exceeded"
            var styled = AttributedString(input)
            if let range = tested.range, let stringRange = Range(range, in: input),
               let attributedRange = Range(stringRange, in: styled) {
                styled[attributedRange].backgroundColor = .yellow
                styled[attributedRange].foregroundColor = .black
            }
            marked = styled
        }
    }
}
