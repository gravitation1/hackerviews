import SwiftUI

@main
struct HackerViewsApp: App {
    @StateObject private var store = RecordStore()
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            MinimumSize(width: 820, height: 580) {
                RootView(store: store).tint(.orange)
            }
            #else
            RootView(store: store).tint(.orange)
            #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        .windowToolbarStyle(.unifiedCompact)
        .commands { PageFindCommands(); ReaderNavigationCommands() }
        #endif
    }
}
