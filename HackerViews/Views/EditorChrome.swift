import SwiftUI

private struct CloseEditorKey: EnvironmentKey { static let defaultValue: (@MainActor () -> Void)? = nil }
extension EnvironmentValues {
    /// Closes an editor shown in the editor panel. Nil where the editor is a
    /// sheet, which closes through `dismiss`.
    var closeEditor: (@MainActor () -> Void)? {
        get { self[CloseEditorKey.self] }
        set { self[CloseEditorKey.self] = newValue }
    }
}

/// An editor's title and its Cancel and confirm buttons around its form. In
/// a sheet they are the navigation title and toolbar; in the editor panel,
/// which has no window chrome of its own, they are drawn the way the sheet
/// draws them: the title in a bar along the top, the buttons in a bar along
/// the bottom.
struct EditorChrome<Content: View>: View {
    let title: String
    var cancel: (() -> Void)?
    let confirmTitle: String
    var confirmDisabled = false
    let confirm: () -> Void
    /// The editor's size on the Mac, as its sheet's content.
    var size: CGSize?
    @ViewBuilder let content: Content
    @Environment(\.closeEditor) private var closeEditor
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        #if os(macOS)
        if closeEditor != nil {
            // At most the sheet's size; shorter in a window too short for it,
            // where the form scrolls.
            panel.frame(width: size?.width).frame(maxHeight: size.map { $0.height + EditorPanelMetrics.sheetTitleBar })
        } else {
            sheet.frame(width: size?.width, height: size?.height)
        }
        #else
        sheet
        #endif
    }

    private var sheet: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .toolbar {
                    if let cancel {
                        ToolbarItem(placement: .cancellationAction) {
                            Button("Cancel", action: cancel).keyboardShortcut(.cancelAction)
                        }
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(confirmTitle, action: confirm).keyboardShortcut(.defaultAction).disabled(confirmDisabled)
                    }
                }
        }
    }

    #if os(macOS)
    private var panel: some View {
        VStack(spacing: 0) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity, minHeight: EditorPanelMetrics.titleBarHeight, alignment: .leading)
                .padding(.leading, 48).padding(.trailing, 20)
                // The sheet's title bar is a shade off its content in both appearances.
                .background(Color(white: colorScheme == .dark ? 39 / 255 : 250 / 255))
                .accessibilityAddTraits(.isHeader)
            Divider()
            content.frame(maxHeight: .infinity)
            Divider()
            HStack(spacing: 8) {
                Spacer()
                if let cancel {
                    // The sheet's Cancel is a plain gray button, not in the accent colour.
                    Button("Cancel", action: cancel).keyboardShortcut(.cancelAction).tint(.primary)
                }
                Button(confirmTitle, action: confirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(confirmDisabled)
            }
            .padding(.horizontal, 20)
            .frame(height: EditorPanelMetrics.buttonBarHeight)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
    #endif
}

/// The sheet's measurements on macOS 26, which the panel reproduces.
enum EditorPanelMetrics {
    static let titleBarHeight: CGFloat = 47.5
    static let buttonBarHeight: CGFloat = 65
    /// How much taller the sheet window is than the editor's frame.
    static let sheetTitleBar: CGFloat = 65
}
