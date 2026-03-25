import SwiftUI

@main
struct MemoryDotApp: App {
    @State private var monitor = MemoryMonitor()

    var body: some Scene {
        MenuBarExtra {
            MenuContentView(monitor: monitor)
        } label: {
            Image(nsImage: monitor.dotImage)
        }
        .menuBarExtraStyle(.menu)
    }
}
