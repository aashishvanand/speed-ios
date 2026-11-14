import Foundation

/// Outcome of a batch of latency probes. `summary` is nil when not one probe
/// came back, in which case `failure` says why — that pair is what the runner
/// turns into a failed run.
struct LatencyProbeResult {
    var summary: LatencySummary?
    var failure: TestFailure?
}

/// Stop the idle-latency batch after this many failures in a row. With a 5 s
/// per-probe timeout, a blackholed network reports in ~15 s rather than
/// spending the whole probe budget (10 × 5 s) on a foregone conclusion.
let maxConsecutiveProbeFailures = 3

/// Per-probe timeout when there's plenty of phase left.
let probeTimeout: TimeInterval = 5

/// Don't start a probe with less than this left before the deadline: it
/// couldn't come back in time, and a half-finished probe is just noise.
let minimumProbeWindow: TimeInterval = 0.25

/// Runs `operation`, but gives up at `deadline` and returns nil, cancelling
/// the operation. Unlike `URLRequest.timeoutInterval` — an *idle* timeout a
/// slowly trickling response can keep resetting — this is a real wall-clock
/// bound.
func withDeadline<T: Sendable>(
    _ deadline: ContinuousClock.Instant,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T? {
    try await withThrowingTaskGroup(of: T?.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(until: deadline, clock: .continuous)
            return nil
        }
        defer { group.cancelAll() }
        // Two children were added, so `next()` always yields a value.
        return try await group.next() ?? nil
    }
}

/// Sleeps for `duration`, cut short at `deadline`. Returns false if the
/// task was cancelled.
private func sleep(_ duration: Duration, notPast deadline: ContinuousClock.Instant) async -> Bool {
    let wake = min(ContinuousClock.now + duration, deadline)
    do {
        try await Task.sleep(until: wake, clock: .continuous)
        return true
    } catch {
        return false
    }
}

/// One probe, bounded by both the per-probe timeout and `deadline`. Returns
/// nil when there isn't time left to start one or it ran out of time.
private func probe(_ client: CloudflareClient, deadline: ContinuousClock.Instant) async throws -> Double? {
    let remaining = (deadline - .now).timeInterval
    guard remaining >= minimumProbeWindow else { return nil }
    return try await withDeadline(deadline) {
        try await client.probeLatencyMs(timeout: min(probeTimeout, remaining))
    }
}

/// Fires sequential `bytes=0` probes and reports each RTT via `onSample`.
///
/// This doubles as the run's connectivity check: it's the first request a
/// test makes, so whatever it fails with is the real reason the test can't
/// continue — no separate reachability pre-flight needed.
///
/// The whole batch, including any in-flight probe, ends by `budget`.
func runLatencyProbes(
    client: CloudflareClient,
    count: Int,
    budget: Duration,
    onSample: @escaping @Sendable (Double) -> Void
) async -> LatencyProbeResult {
    let deadline = ContinuousClock.now + budget
    var samples: [Double] = []
    var lastFailure: TestFailure?
    var consecutiveFailures = 0

    for index in 0..<count {
        if Task.isCancelled { break }
        do {
            guard let ms = try await probe(client, deadline: deadline) else {
                // Out of time. If nothing ever came back, that's a timeout.
                if samples.isEmpty, lastFailure == nil { lastFailure = .unreachable }
                break
            }
            samples.append(ms)
            consecutiveFailures = 0
            onSample(ms)
        } catch {
            if Task.isCancelled { break }
            let failure = TestFailure(probeError: error)
            lastFailure = failure
            consecutiveFailures += 1
            // Airplane mode or a disallowed interface won't resolve itself
            // mid-run, so stop at once. Timeouts get a couple of retries,
            // but not an unbounded number.
            if samples.isEmpty, failure.isTerminal { break }
            if consecutiveFailures >= maxConsecutiveProbeFailures { break }
        }
        // No pause after the last probe — it would only delay the phase.
        guard index < count - 1, await sleep(.milliseconds(100), notPast: deadline) else { break }
    }

    return LatencyProbeResult(summary: LatencySummary(samples: samples), failure: lastFailure)
}

/// Runs latency probes continuously for `duration`, used as the "loaded"
/// latency measurement that overlaps a download/upload phase. Returns nil
/// when nothing came back, so callers can tell "unmeasured" apart from a
/// genuine 0 ms — the distinction the quality scoring depends on.
///
/// Never holds the phase open past `duration`: each probe and each pause is
/// bounded by the time remaining.
func runLoadedLatencyProbes(
    client: CloudflareClient,
    duration: TimeInterval,
    onSample: @escaping @Sendable (Double) -> Void
) async -> LatencySummary? {
    let deadline = ContinuousClock.now + .seconds(duration)
    var samples: [Double] = []
    while !Task.isCancelled, (deadline - .now).timeInterval >= minimumProbeWindow {
        if let ms = try? await probe(client, deadline: deadline) {
            samples.append(ms)
            onSample(ms)
        }
        guard (deadline - .now).timeInterval >= minimumProbeWindow,
              await sleep(.milliseconds(200), notPast: deadline) else { break }
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
