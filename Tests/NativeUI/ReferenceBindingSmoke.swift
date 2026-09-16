import SwiftUI

@main struct ReferenceBindingSmoke {
    @MainActor static func main() {
        let first = Citation(url: "https://news.ycombinator.com/item?id=1", author: "one", excerpt: "First", context: "First")
        let second = Citation(url: "https://news.ycombinator.com/item?id=2", author: "two", excerpt: "Second", context: "Second")
        var references = [first, second]
        let collection = Binding(get: { references }, set: { references = $0 })
        // Retain the same projected text binding SwiftUI's field keeps between updates.
        let field = referenceBinding(in: collection, reference: second).annotation
        field.wrappedValue = "Initial note"
        precondition(references[1].annotation == "Initial note")

        references.removeFirst()
        precondition(field.wrappedValue == "Initial note")
        field.wrappedValue = "After earlier row removed"
        precondition(references[0].id == second.id && references[0].annotation == "After earlier row removed")

        references.insert(first, at: 0)
        references.reverse()
        field.wrappedValue = "After reorder"
        precondition(references[0].annotation == "After reorder" && references[1].annotation.isEmpty)

        references.removeAll { $0.id == second.id }
        _ = field.wrappedValue
        field.wrappedValue = "Late update after deletion"
        precondition(references == [first], "A removed row must not edit its replacement")

        references = []
        _ = field.wrappedValue
        field.wrappedValue = "Late update after clearing history"
        precondition(references.isEmpty, "A stale field must not resurrect a reference")

        var restored = second
        restored.annotation = "Restored note"
        restored.excerpt = "Restored excerpt"
        references = [restored, first]
        precondition(field.wrappedValue == "Restored note")
        field.wrappedValue = "Editing restored note"
        precondition(references[0].annotation == "Editing restored note")
        precondition(references[0].excerpt == "Restored excerpt")
        precondition(references[1] == first)
        print("PASS reference bindings: edits, removal, reorder, empty list, history replacement, and late callbacks")
    }
}
