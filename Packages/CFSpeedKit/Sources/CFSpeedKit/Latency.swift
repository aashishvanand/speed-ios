import Foundation

/// Fires sequential `bytes=0` probes and reports each RTT via `onSample`.
/// Used both for idle latency (before any transfer) and loaded latency
/// (concurrently with a download/upload phase, from the runner).
func runLatencyProbes(
    client: CloudflareClient,
    count: Int,
    onSample: @escaping @Sendable (Double) -> Void
) async -> LatencySummary {
    var samples: [Double] = []
    for _ in 0..<count {
        if let ms = await client.probeLatencyMs() {
            samples.append(ms)
            onSample(ms)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }
    return LatencySummary(samples: samples) ?? .failed
}

/// Runs latency probes continuously for `duration`, used as the "loaded"
/// latency measurement that overlaps a download/upload phase.
func runLoadedLatencyProbes(
    client: CloudflareClient,
    duration: TimeInterval,
    onSample: @escaping @Sendable (Double) -> Void
) async -> LatencySummary {
    var samples: [Double] = []
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        if let ms = await client.probeLatencyMs() {
            samples.append(ms)
            onSample(ms)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    return LatencySummary(samples: samples) ?? .failed
}
