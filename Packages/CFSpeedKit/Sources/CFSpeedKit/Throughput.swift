import Foundation

/// What a throughput phase produced, plus why it may have produced nothing.
struct PhaseOutcome: Sendable {
    var summary: ThroughputSummary
    /// The last non-2xx status the server answered with, if any. When a phase
    /// moved no bytes, this is the reason to report.
    var lastRejectedStatus: Int?
}

/// One throughput sample: Mbps over the interval `start..<end`, both measured
/// in seconds since the phase began.
struct ThroughputSample: Sendable, Equatable {
    var start: TimeInterval
    var end: TimeInterval
    var mbps: Double
}

/// Runs `concurrency` parallel download workers against /__down for `duration`,
/// sampling cumulative bytes every `sampleInterval` and emitting instantaneous
/// Mbps via `onTick`. Mirrors cloudflare-speed-cli's approach: fixed-duration
/// (not fixed-bytes) phases, ramp-up discarded from the final summary.
func runDownloadPhase(
    client: CloudflareClient,
    config: SpeedTestConfig,
    onMeta: @escaping @Sendable (NetworkMeta) -> Void,
    onTick: @escaping @Sendable (Double, UInt64) -> Void
) async -> PhaseOutcome {
    let metaCaptured = OneShot()
    return await measureThroughput(
        concurrency: config.concurrency,
        duration: config.downloadDuration,
        sampleInterval: config.sampleInterval,
        onTick: onTick
    ) { counter in
        var requestBytes = config.downloadBytesPerRequest
        while !Task.isCancelled {
            let task = client.session.dataTask(with: URLRequest(url: client.downURL(bytes: requestBytes)))
            let started = ContinuousClock.now
            let delegate = TransferDelegate(direction: .download, counter: counter) { response in
                // Only a real answer's headers describe the edge we're testing.
                guard (response as? HTTPURLResponse)?.isSuccess == true, metaCaptured.claim() else { return }
                onMeta(client.meta(from: response))
            }
            do {
                let outcome = try await runTransfer(task, delegate: delegate)
                if let status = outcome.rejectedStatus {
                    counter.recordRejection(status: status)
                    try? await Task.sleep(for: .milliseconds(100))
                } else if outcome.response == nil {
                    counter.recordError()
                    try? await Task.sleep(for: .milliseconds(100))
                } else if outcome.bytesReceived == 0 {
                    // A 2xx with no body (a proxy answering for the edge)
                    // returns at once; without a pause six workers would
                    // spin on it for the whole phase.
                    counter.recordError()
                    try? await Task.sleep(for: .milliseconds(100))
                } else {
                    requestBytes = nextDownloadRequestSize(
                        requested: requestBytes,
                        received: outcome.bytesReceived,
                        elapsed: (ContinuousClock.now - started).timeInterval,
                        floor: config.downloadBytesPerRequest
                    )
                }
            } catch {
                if Task.isCancelled { break }
                counter.recordError()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// How long a download request should ideally last. Long enough that
/// starting the next request is a small share of a worker's time, short
/// enough that one request is a small share of the phase.
let targetDownloadRequestSeconds: TimeInterval = 1

/// Size of a worker's next download request. On a fast link a fixed size
/// finishes in a fraction of a second (25 MB takes 0.02 s at 10 Gbps), so
/// per-request setup eats into the measurement; the size grows to what the
/// last request's rate would move in `targetDownloadRequestSeconds`.
///
/// Grows only from a request that delivered its whole body: a short body
/// says nothing about the link's rate. Never drops below `floor` (the
/// configured size) or rises past `SpeedTestConfig.maxDownloadBytesPerRequest`.
func nextDownloadRequestSize(requested: Int, received: UInt64, elapsed: TimeInterval, floor: Int) -> Int {
    guard received >= UInt64(requested), elapsed > 0, elapsed.isFinite else { return requested }
    let bytesPerSecond = Double(received) / elapsed
    let target = bytesPerSecond * targetDownloadRequestSeconds
    let ceiling = SpeedTestConfig.maxDownloadBytesPerRequest
    guard target.isFinite else { return ceiling }
    return min(max(Int(min(target, Double(ceiling))), floor), ceiling)
}

/// Runs `concurrency` parallel upload workers against /__up for `duration`.
func runUploadPhase(
    client: CloudflareClient,
    config: SpeedTestConfig,
    onTick: @escaping @Sendable (Double, UInt64) -> Void
) async -> PhaseOutcome {
    // One zero-filled buffer shared (copy-on-write) by every request.
    let body = Data(count: config.uploadBytesPerRequest)
    return await measureThroughput(
        concurrency: config.concurrency,
        duration: config.uploadDuration,
        sampleInterval: config.sampleInterval,
        onTick: onTick
    ) { counter in
        while !Task.isCancelled {
            var request = URLRequest(url: client.upURL())
            request.httpMethod = "POST"
            request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
            let task = client.session.uploadTask(with: request, from: body)
            let delegate = TransferDelegate(direction: .upload(bodyLength: UInt64(body.count)), counter: counter)
            do {
                let outcome = try await runTransfer(task, delegate: delegate)
                if let status = outcome.rejectedStatus {
                    // The server refused the body, so what we sent wasn't
                    // throughput. Take it back out of the total.
                    counter.subtract(outcome.bytesSent)
                    counter.recordRejection(status: status)
                    try? await Task.sleep(for: .milliseconds(100))
                } else if outcome.response == nil {
                    counter.recordError()
                    try? await Task.sleep(for: .milliseconds(100))
                }
            } catch {
                // Cut short by the phase deadline: those bytes really went out
                // over the link, so they stay counted.
                if Task.isCancelled { break }
                counter.recordError()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// The next sampling tick, as seconds since the phase began.
///
/// Normally one `interval` after `previous`. After a late wakeup (the
/// process was descheduled, the pool was saturated) it skips straight to the
/// first tick still in the future: firing every overdue tick back-to-back
/// would produce samples over a near-zero Δt that read as absurdly high or
/// as 0. Never past `end`.
func nextTickOffset(after previous: TimeInterval, now: TimeInterval, interval: TimeInterval, end: TimeInterval) -> TimeInterval {
    var next = previous + interval
    if next <= now {
        let skipped = ((now - previous) / interval).rounded(.down)
        next = previous + (skipped + 1) * interval
    }
    return min(next, end)
}

/// Shared phase driver: starts `concurrency` copies of `worker`, samples the
/// shared byte counter on a fixed schedule for `duration`, then cancels every
/// worker — tearing in-flight transfers down mid-stream so the phase ends when
/// its duration does, not when the slowest request finishes.
///
/// Ticks are scheduled against absolute deadlines on a monotonic clock
/// (`sleep(until:)`), so scheduling jitter never accumulates into drift, and
/// each tick's Mbps is computed from the *measured* time since the previous
/// snapshot rather than the nominal interval.
private func measureThroughput(
    concurrency: Int,
    duration: TimeInterval,
    sampleInterval: TimeInterval,
    onTick: @escaping @Sendable (Double, UInt64) -> Void,
    worker: @escaping @Sendable (ByteCounter) async -> Void
) async -> PhaseOutcome {
    let counter = ByteCounter()
    let clock = ContinuousClock()
    var samples: [ThroughputSample] = []
    var measuredSeconds: TimeInterval = 0

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<concurrency {
            group.addTask { await worker(counter) }
        }

        let start = clock.now
        var tick: TimeInterval = 0
        var lastOffset: TimeInterval = 0
        var lastBytes: UInt64 = 0

        while lastOffset < duration {
            tick = nextTickOffset(after: tick, now: (clock.now - start).timeInterval, interval: sampleInterval, end: duration)
            do {
                try await clock.sleep(until: start + .seconds(tick), tolerance: .milliseconds(5))
            } catch {
                break // cancelled
            }
            let offset = (clock.now - start).timeInterval
            let bytes = counter.snapshot().total
            let elapsed = offset - lastOffset
            guard elapsed > 0 else { continue }
            let delta = bytes >= lastBytes ? bytes - lastBytes : 0
            let mbps = (Double(delta) * 8.0) / elapsed / 1_000_000.0
            samples.append(ThroughputSample(start: lastOffset, end: offset, mbps: mbps))
            lastBytes = bytes
            lastOffset = offset
            onTick(mbps, bytes)
        }
        measuredSeconds = lastOffset
        group.cancelAll()
    }

    return PhaseOutcome(
        summary: summarize(
            totalBytes: counter.snapshot().total,
            samples: samples,
            duration: measuredSeconds > 0 ? measuredSeconds : duration
        ),
        lastRejectedStatus: counter.lastRejectedStatus
    )
}

/// Length of the ramp-up window dropped from the summary: the first 20% of
/// the phase, at least 1 s (TCP slow start doesn't care how long the phase
/// is), but never more than half, so a very short phase keeps some samples.
func rampUpSeconds(forDuration duration: TimeInterval) -> TimeInterval {
    min(max(0.2 * duration, 1), 0.5 * duration)
}

/// Mirrors cloudflare-speed-cli: drop the ramp-up samples before computing
/// percentiles, so TCP slow start doesn't drag the reported throughput down.
/// The window is measured in time from each sample's own timestamps, not in
/// sample counts, so it holds whatever the tick rate or late wakeups did.
func summarize(totalBytes: UInt64, samples allSamples: [ThroughputSample], duration: Double) -> ThroughputSummary {
    let fallbackMbps = duration > 0 ? (Double(totalBytes) * 8.0) / duration / 1_000_000.0 : 0

    // A millisecond of slack so a tick that lands a hair before the boundary
    // isn't thrown out as ramp-up.
    let rampEnd = rampUpSeconds(forDuration: duration) - 0.001
    let steady = allSamples.filter { $0.start >= rampEnd }.map(\.mbps)
    let values = steady.isEmpty ? [fallbackMbps] : steady

    let sorted = values.sorted()
    func percentile(_ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let idx = min(sorted.count - 1, max(0, Int(Double(sorted.count - 1) * p)))
        return sorted[idx]
    }
    let mean = sorted.reduce(0, +) / Double(sorted.count)

    return ThroughputSummary(
        bytes: totalBytes,
        durationSeconds: duration,
        meanMbps: mean,
        medianMbps: percentile(0.5),
        p25Mbps: percentile(0.25),
        p75Mbps: percentile(0.75),
        p90Mbps: percentile(0.90)
    )
}
