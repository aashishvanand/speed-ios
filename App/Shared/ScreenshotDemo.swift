import SwiftUI
import SwiftData
import CFSpeedKit

/// Debug-only screenshot mode. Launch with `-demo result`, `-demo download`,
/// `-demo details` or `-demo history` (scripts/take-screenshots.sh does) to show made-up but
/// representative numbers with no network traffic, no automatic test, and no
/// real IP address on screen. Release builds compile all of this out.
enum ScreenshotDemo {
    enum Scene: String {
        case result, download, details, history
    }

    #if DEBUG
    static let scene: Scene? = UserDefaults.standard.string(forKey: "demo").flatMap(Scene.init(rawValue:))
    #else
    static let scene: Scene? = nil
    #endif

    static var isActive: Bool { scene != nil }

    /// The container the app should use: the real store, or a throwaway one
    /// seeded with sample history in demo mode.
    @MainActor
    static var modelContainer: ModelContainer {
        #if DEBUG
        if isActive { return seededContainer }
        #endif
        return HistoryStore.container
    }

    #if DEBUG
    @MainActor
    private static let seededContainer: ModelContainer = {
        let container = HistoryStore.previewContainer()
        let context = container.mainContext
        let now = Date.now
        let rows: [(TimeInterval, Double, Double, Double, ConnectionType)] = [
            (-60 * 4, 487.3, 92.4, 11, .wifi),
            (-3600 * 5, 512.8, 95.1, 10, .wifi),
            (-86_400 * 1 - 3600 * 2, 941.6, 902.3, 4, .wiredEthernet),
            (-86_400 * 1 - 3600 * 9, 186.2, 41.7, 27, .cellular),
            (-86_400 * 2, 463.9, 88.0, 12, .wifi),
            (-86_400 * 3 - 3600 * 4, 498.4, 93.6, 11, .wifi),
            (-86_400 * 4, 224.5, 38.2, 31, .cellular),
            (-86_400 * 5 - 3600 * 7, 935.2, 897.8, 5, .wiredEthernet),
            (-86_400 * 6, 476.0, 90.9, 13, .wifi),
        ]
        for (offset, down, up, ping, type) in rows {
            context.insert(TestHistoryEntry(
                date: now.addingTimeInterval(offset),
                downloadMbps: down,
                uploadMbps: up,
                pingMs: ping,
                jitterMs: 1.6,
                ispName: type == .cellular ? "Example Mobile" : "Example Fiber",
                connectionType: type
            ))
        }
        try? context.save()
        return container
    }()

    /// Puts the runner into the state for `scene`.
    @MainActor
    static func apply(_ scene: Scene, to runner: SpeedTestRunner) {
        let download = samples(peak: 487, count: 40, seed: 3)
        let upload = samples(peak: 92, count: 40, seed: 11)
        switch scene {
        case .download:
            runner.showDemoState(phase: .download, result: nil, downloadSamples: Array(download.prefix(27)), uploadSamples: [], latencyMs: 19)
        case .result, .details, .history:
            runner.showDemoState(phase: .finished, result: result, downloadSamples: download, uploadSamples: upload, latencyMs: 11)
        }
    }

    /// Addresses and AS numbers come from the ranges reserved for
    /// documentation (RFC 5737, RFC 5398), so nothing real appears.
    private static let result = TestResult(
        meta: NetworkMeta(
            clientIP: "203.0.113.42",
            colo: "SJC",
            city: "San Jose",
            country: "US",
            asn: "64500",
            ispName: "Example Fiber",
            latitude: 37.3626,
            longitude: -121.9291
        ),
        idleLatency: LatencySummary(samples: [10.8, 11.4, 10.9, 12.6, 11.1, 10.7, 13.0, 11.2, 10.9, 11.6, 12.1, 10.8, 11.0, 11.9, 10.6, 11.3, 12.4, 11.0, 10.9, 11.5])!,
        download: ThroughputSummary(bytes: 452_000_000, durationSeconds: 8, meanMbps: 452.1, medianMbps: 468.9, p25Mbps: 431.2, p75Mbps: 479.5, p90Mbps: 487.3),
        downloadLoadedLatency: LatencySummary(samples: [18.2, 21.5, 19.8, 24.1, 20.3, 22.7, 19.1, 23.4, 20.9, 21.8]),
        upload: ThroughputSummary(bytes: 86_000_000, durationSeconds: 8, meanMbps: 86.4, medianMbps: 89.7, p25Mbps: 83.0, p75Mbps: 91.2, p90Mbps: 92.4),
        uploadLoadedLatency: LatencySummary(samples: [24.6, 27.9, 25.3, 29.8, 26.1, 28.4, 25.7, 27.2, 26.8, 30.1])
    )

    /// A plausible throughput trace: a TCP ramp-up, then noise around the peak.
    private static func samples(peak: Double, count: Int, seed: UInt64) -> [Double] {
        var state = seed
        func noise() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 33) / Double(1 << 31) - 0.5
        }
        return (0..<count).map { i in
            let ramp = min(1, Double(i + 1) / 7)
            return max(0, peak * (0.9 * ramp + 0.08 * noise() + 0.02))
        }
    }
    #endif
}
