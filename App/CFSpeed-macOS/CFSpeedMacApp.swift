import SwiftUI
import CFSpeedKit

@main
struct CFSpeedMacApp: App {
    var body: some Scene {
        WindowGroup {
            SpeedTestView()
        }
        // Local-only store (CloudKit explicitly off) with retention; a seeded
        // in-memory one in Debug screenshot mode.
        .modelContainer(ScreenshotDemo.modelContainer)
        .windowResizability(.contentSize)
    }
}
