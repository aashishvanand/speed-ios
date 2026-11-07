import Foundation

/// Outcome of a batch of latency probes. `summary` is nil when not one probe
/// came back, in which case `error` says why — that pair is what the runner
/// turns into a `TestFailure`.
struct LatencyProbeResult {
    var summary: LatencySummary?
    var error: URLError?
}

/// Stop the idle-latency batch after this many failures in a row. With a 5 s
/// per-probe timeout, a blackholed network reports in ~15 s rather than
/// spending the whole probe budget (10 × 5 s) on a foregone conclusion.
let maxConsecutiveProbeFailures = 3

/// Hard ceiling on the whole idle-latency batch, whatever the mix of
/// successes and failures.
let idleLatencyBudget: Duration = .seconds(15)

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
    let clock = ContinuousClock()
    let deadline = clock.now + idleLatencyBudget
    var samples: [Double] = []
    var lastError: URLError?
    var consecutiveFailures = 0

    for _ in 0..<count {
        if Task.isCancelled || clock.now >= deadline { break }
        do {
            let ms = try await client.probeLatencyMs()
            samples.append(ms)
            consecutiveFailures = 0
            onSample(ms)
        } catch let error as URLError {
            lastError = error
            consecutiveFailures += 1
            // Airplane mode or a disallowed interface won't resolve itself
            // mid-run, so stop at once. Timeouts get a couple of retries,
            // but not an unbounded number.
            if samples.isEmpty, TestFailure(error).isTerminal { break }
            if consecutiveFailures >= maxConsecutiveProbeFailures { break }
        } catch {
            lastError = URLError(.unknown)
            consecutiveFailures += 1
            if consecutiveFailures >= maxConsecutiveProbeFailures { break }
        }
        do {
            try await Task.sleep(for: .milliseconds(100))
        } catch {
            break
        }
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
    let clock = ContinuousClock()
    let deadline = clock.now + .seconds(duration)
    var samples: [Double] = []
    while !Task.isCancelled, clock.now < deadline {
        // Never let an in-flight probe hold the phase open past its end.
        let remaining = (deadline - clock.now).timeInterval
        if let ms = try? await client.probeLatencyMs(timeout: min(5, max(0.5, remaining))) {
            samples.append(ms)
            onSample(ms)
        }
        do {
            try await Task.sleep(for: .milliseconds(200))
        } catch {
            break
        }
    }
    return LatencySummary(samples: samples)
}

extension Duration {
    /// Seconds as a `Double`, for rate arithmetic.
    var timeInterval: TimeInterval {
        let (seconds, attoseconds) = components
        return Double(seconds) + Double(attoseconds) / 1e18
    }
}
