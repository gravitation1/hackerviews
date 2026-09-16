import SwiftUI

@main
struct QuietHNApp: App {
    @StateObject private var store = RecordStore()
    var body: some Scene {
        WindowGroup {
            RootView(store: store)
                .tint(.orange)
                #if os(macOS)
                .frame(minWidth: 820, minHeight: 580)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1180, height: 820)
        #endif
    }
}
