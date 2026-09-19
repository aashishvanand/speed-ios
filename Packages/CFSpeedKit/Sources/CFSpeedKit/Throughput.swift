import Foundation

/// Runs `concurrency` parallel download workers against /__down for `duration`,
/// sampling cumulative bytes every `sampleInterval` and emitting instantaneous
/// Mbps via `onTick`. Mirrors cloudflare-speed-cli's approach: fixed-duration
/// (not fixed-bytes) phases, ramp-up discarded from the final summary.
func runDownloadPhase(
    client: CloudflareClient,
    config: SpeedTestConfig,
    onTick: @escaping @Sendable (Double, UInt64) -> Void
) async -> ThroughputSummary {
    let counter = ByteCounter()
    let stop = Stopper()
    let collector = SampleCollector()

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<config.concurrency {
            group.addTask {
                while await !stop.isStopped {
                    let url = client.downURL(bytes: config.downloadBytesPerRequest)
                    do {
                        let (bytes, response) = try await client.session.bytes(for: URLRequest(url: url))
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                            await counter.recordError()
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            continue
                        }
                        var buffer = 0
                        for try await _ in bytes {
                            buffer += 1
                            if buffer >= 16_384 {
                                await counter.add(UInt64(buffer))
                                buffer = 0
                                if await stop.isStopped { break }
                            }
                        }
                        if buffer > 0 {
                            await counter.add(UInt64(buffer))
                        }
                    } catch {
                        await counter.recordError()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
        }

        group.addTask {
            var lastBytes: UInt64 = 0
            var elapsed: Double = 0
            let interval = config.sampleInterval

            while elapsed < config.downloadDuration {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                elapsed += interval
                let now = await counter.snapshot().total
                let delta = now >= lastBytes ? now - lastBytes : 0
                let mbps = (Double(delta) * 8.0) / interval / 1_000_000.0
                lastBytes = now
                await collector.record(mbps)
                onTick(mbps, now)
            }
            await stop.stop()
        }
    }

    return await summarize(counter: counter, collector: collector, duration: config.downloadDuration)
}

/// Runs `concurrency` parallel upload workers against /__up for `duration`.
func runUploadPhase(
    client: CloudflareClient,
    config: SpeedTestConfig,
    onTick: @escaping @Sendable (Double, UInt64) -> Void
) async -> ThroughputSummary {
    let counter = ByteCounter()
    let stop = Stopper()
    let collector = SampleCollector()
    let body = Data(count: config.uploadBytesPerRequest)

    await withTaskGroup(of: Void.self) { group in
        for _ in 0..<config.concurrency {
            group.addTask {
                while await !stop.isStopped {
                    var request = URLRequest(url: client.upURL())
                    request.httpMethod = "POST"
                    request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
                    let delegate = UploadProgressDelegate(counter: counter)
                    do {
                        let (_, response) = try await client.session.upload(for: request, from: body, delegate: delegate)
                        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                            await counter.recordError()
                            try? await Task.sleep(nanoseconds: 100_000_000)
                            continue
                        }
                    } catch {
                        await counter.recordError()
                        try? await Task.sleep(nanoseconds: 100_000_000)
                    }
                }
            }
        }

        group.addTask {
            var lastBytes: UInt64 = 0
            var elapsed: Double = 0
            let interval = config.sampleInterval

            while elapsed < config.uploadDuration {
                try? await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
                elapsed += interval
                let now = await counter.snapshot().total
                let delta = now >= lastBytes ? now - lastBytes : 0
                let mbps = (Double(delta) * 8.0) / interval / 1_000_000.0
                lastBytes = now
                await collector.record(mbps)
                onTick(mbps, now)
            }
            await stop.stop()
        }
    }

    return await summarize(counter: counter, collector: collector, duration: config.uploadDuration)
}

/// Mirrors cloudflare-speed-cli: drop the ramp-up (first 20%, min 1s) of
/// per-tick samples before computing percentiles, so TCP slow start doesn't
/// drag the reported throughput down.
private func summarize(counter: ByteCounter, collector: SampleCollector, duration: Double) async -> ThroughputSummary {
    let snap = await counter.snapshot()
    let allSamples = await collector.samples()
    let fallbackMbps = duration > 0 ? (Double(snap.total) * 8.0) / duration / 1_000_000.0 : 0

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
        bytes: snap.total,
        durationSeconds: duration,
        meanMbps: mean,
        medianMbps: percentile(0.5),
        p25Mbps: percentile(0.25),
        p75Mbps: percentile(0.75),
        p90Mbps: percentile(0.90)
    )
}

/// Simple actor-backed stop flag shared between worker tasks and the sampling clock.
actor Stopper {
    private(set) var isStopped = false
    func stop() { isStopped = true }
}

/// Collects per-tick Mbps samples for post-hoc percentile computation.
actor SampleCollector {
    private var values: [Double] = []
    func record(_ v: Double) { values.append(v) }
    func samples() -> [Double] { values }
}
