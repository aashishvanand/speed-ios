import Foundation

/// Runs `concurrency` parallel download workers against /__down for `duration`,
/// sampling cumulative bytes every `sampleInterval` and emitting instantaneous
/// Mbps via `onTick`. Mirrors cloudflare-speed-cli's approach: fixed-duration
/// (not fixed-bytes) phases, ramp-up discarded from the final summary.
func runDownloadPhase(
    client: CloudflareClient,
    config: SpeedTestConfig,
    onMeta: @escaping @Sendable (NetworkMeta) -> Void,
    onTick: @escaping @Sendable (Double, UInt64) -> Void
) async -> ThroughputSummary {
    let metaCaptured = OneShot()
    return await measureThroughput(
        concurrency: config.concurrency,
        duration: config.downloadDuration,
        sampleInterval: config.sampleInterval,
        onTick: onTick
    ) { counter in
        while !Task.isCancelled {
            let url = client.downURL(bytes: config.downloadBytesPerRequest)
            do {
                let response = try await streamDownload(
                    session: client.session,
                    request: URLRequest(url: url),
                    counter: counter
                ) { response in
                    guard metaCaptured.claim() else { return }
                    onMeta(client.meta(from: response))
                }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    counter.recordError()
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
            } catch {
                if Task.isCancelled { break }
                counter.recordError()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

/// Runs `concurrency` parallel upload workers against /__up for `duration`.
func runUploadPhase(
    client: CloudflareClient,
    config: SpeedTestConfig,
    onTick: @escaping @Sendable (Double, UInt64) -> Void
) async -> ThroughputSummary {
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
            let delegate = UploadProgressDelegate(counter: counter)
            do {
                // The async upload API cancels the in-flight transfer when
                // this task is cancelled, so the phase ends on time even when
                // a single 5 MB body would take far longer than the phase.
                let (_, response) = try await client.session.upload(for: request, from: body, delegate: delegate)
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                    counter.recordError()
                    try? await Task.sleep(for: .milliseconds(100))
                    continue
                }
            } catch {
                if Task.isCancelled { break }
                counter.recordError()
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
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
) async -> ThroughputSummary {
    let counter = ByteCounter()
    let clock = ContinuousClock()
    var samples: [Double] = []
    var measuredSeconds: TimeInterval = 0

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<concurrency {
            group.addTask { await worker(counter) }
        }

        let start = clock.now
        let end = start + .seconds(duration)
        let interval = Duration.seconds(sampleInterval)
        var nextTick = start
        var lastInstant = start
        var lastBytes: UInt64 = 0

        while lastInstant < end {
            nextTick = min(nextTick + interval, end)
            do {
                try await clock.sleep(until: nextTick, tolerance: .milliseconds(5))
            } catch {
                break // cancelled
            }
            let now = clock.now
            let bytes = counter.snapshot().total
            let elapsed = (now - lastInstant).timeInterval
            guard elapsed > 0 else { continue }
            let delta = bytes >= lastBytes ? bytes - lastBytes : 0
            let mbps = (Double(delta) * 8.0) / elapsed / 1_000_000.0
            lastBytes = bytes
            lastInstant = now
            samples.append(mbps)
            onTick(mbps, bytes)
        }
        measuredSeconds = (lastInstant - start).timeInterval
        group.cancelAll()
    }

    return summarize(
        totalBytes: counter.snapshot().total,
        samples: samples,
        duration: measuredSeconds > 0 ? measuredSeconds : duration
    )
}

/// Mirrors cloudflare-speed-cli: drop the ramp-up (first 20%, min 1s) of
/// per-tick samples before computing percentiles, so TCP slow start doesn't
/// drag the reported throughput down.
func summarize(totalBytes: UInt64, samples allSamples: [Double], duration: Double) -> ThroughputSummary {
    let fallbackMbps = duration > 0 ? (Double(totalBytes) * 8.0) / duration / 1_000_000.0 : 0

    let rampFraction = 0.20
    let rampCount = max(Int(Double(allSamples.count) * rampFraction), duration >= 1 ? 1 : 0)
    let steady = allSamples.count > rampCount ? Array(allSamples[rampCount...]) : allSamples
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
