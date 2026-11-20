import SwiftUI
import CFSpeedKit

@main
struct CFSpeedMacApp: App {
    var body: some Scene {
        // One window, not a WindowGroup: every window owns a runner that
        // starts by itself, and two tests at once skew each other, double
        // the data and save two history rows. `Window` also drops
        // File → New Window.
        Window("Edge Speed", id: "main") {
            SpeedTestView()
        }
        // Local-only store (CloudKit explicitly off) with retention; a seeded
        // in-memory one in Debug screenshot mode.
        .modelContainer(ScreenshotDemo.modelContainer)
        .windowResizability(.contentSize)
    }
}
