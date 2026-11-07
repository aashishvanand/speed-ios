import Foundation

/// Outcome of a batch of latency probes. `summary` is nil when not one probe
/// came back, in which case `error` says why — that pair is what the runner
/// turns into a `TestFailure`.
struct LatencyProbeResult {
    var summary: LatencySummary?
    var error: URLError?
}

/// Fires sequential `bytes=0` probes and reports each RTT via `onSample`.
///
/// This doubles as the run's connectivity check: it's the first request a
/// test makes, so whatever it fails with is the real reason the test can't
/// continue — no separate reachability pre-flight needed.
func runLatencyProbes(
    client: CloudflareClient,
    count: Int,
    onSample: @escaping @Sendable (Double) -> Void
) async -> LatencyProbeResult {
    var samples: [Double] = []
    var lastError: URLError?

    for _ in 0..<count {
        do {
            let ms = try await client.probeLatencyMs()
            samples.append(ms)
            onSample(ms)
        } catch let error as URLError {
            lastError = error
            // Airplane mode or a disallowed interface won't resolve itself
            // mid-run, so stop rather than spending the whole probe budget
            // on a foregone conclusion. Timeouts still get their retries.
            if samples.isEmpty, TestFailure(error).isTerminal { break }
        } catch {
            lastError = URLError(.unknown)
        }
        try? await Task.sleep(nanoseconds: 100_000_000)
    }

    return LatencyProbeResult(summary: LatencySummary(samples: samples), error: lastError)
}

/// Runs latency probes continuously for `duration`, used as the "loaded"
/// latency measurement that overlaps a download/upload phase. Returns nil
/// when nothing came back, so callers can tell "unmeasured" apart from a
/// genuine 0 ms — the distinction the quality scoring depends on.
func runLoadedLatencyProbes(
    client: CloudflareClient,
    duration: TimeInterval,
    onSample: @escaping @Sendable (Double) -> Void
) async -> LatencySummary? {
    var samples: [Double] = []
    let deadline = Date().addingTimeInterval(duration)
    while Date() < deadline {
        if let ms = try? await client.probeLatencyMs() {
            samples.append(ms)
            onSample(ms)
        }
        try? await Task.sleep(nanoseconds: 200_000_000)
    }
    return LatencySummary(samples: samples)
}
