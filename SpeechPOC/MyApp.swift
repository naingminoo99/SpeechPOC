import SwiftUI

@main struct MyApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                #if os(macOS)
                .frame(minWidth: 420, maxWidth: .infinity, minHeight: 560, maxHeight: .infinity)
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 640, height: 860)
        .windowResizability(.contentMinSize)
        // Always open at the default size instead of restoring the last window frame.
        .restorationBehavior(.disabled)
        #endif
    }
}
