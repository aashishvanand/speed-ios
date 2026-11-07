import SwiftUI
import CFSpeedKit

@main
struct CFSpeedApp: App {
    var body: some Scene {
        WindowGroup {
            SpeedTestView()
        }
        // Local-only store (CloudKit explicitly off) with retention.
        .modelContainer(HistoryStore.container)
    }
}
