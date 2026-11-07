import SwiftUI
import CFSpeedKit

@main
struct CFSpeedMacApp: App {
    var body: some Scene {
        WindowGroup {
            SpeedTestView()
        }
        // Local-only store (CloudKit explicitly off) with retention.
        .modelContainer(HistoryStore.container)
        .windowResizability(.contentSize)
    }
}
