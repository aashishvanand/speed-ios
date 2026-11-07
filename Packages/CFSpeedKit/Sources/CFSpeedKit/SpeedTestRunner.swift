import Foundation
import Observation

/// Orchestrates a full Cloudflare speed test run: idle latency, download
/// (with loaded latency), upload (with loaded latency).
///
/// `@Observable` rather than `ObservableObject`: live ticks land at 5 Hz, and
/// Observation invalidates only the views that actually read the property that
/// changed, instead of the whole screen on every `@Published` write.
@MainActor
@Observable
public final class SpeedTestRunner {
    public private(set) var phase: TestPhase = .idle
    public private(set) var meta = NetworkMeta()
    public private(set) var downloadMbps: Double = 0
    public private(set) var uploadMbps: Double = 0
    public private(set) var latencyMs: Double = 0
    public private(set) var result: TestResult?

    /// Instantaneous Mbps samples (one per `sampleInterval` tick) for the
    /// currently running or most recently completed phase — used to draw the
    /// live throughput graph behind the hero number. Bounded by
    /// duration / sampleInterval (40 at the defaults).
    public private(set) var downloadSamples: [Double] = []
    public private(set) var uploadSamples: [Double] = []

    public var isRunning: Bool {
        switch phase {
        case .idle, .finished, .failed: return false
        default: return true
        }
    }

    private let config: SpeedTestConfig

    // Everything belonging to the current run, cancelled together. All
    // mutation happens on the main actor and checks cancellation first, so a
    // superseded run can never write over a newer one.
    @ObservationIgnored private var runTask: Task<Void, Never>?
    @ObservationIgnored private var metadataTask: Task<Void, Never>?
    @ObservationIgnored private var eventTask: Task<Void, Never>?

    /// Metadata from /cdn-cgi/trace + /meta, and from the first download's
    /// response headers. Kept apart and recombined in a fixed precedence so
    /// the result doesn't depend on which request happened to land first.
    @ObservationIgnored private var fetchedMeta = NetworkMeta()
    @ObservationIgnored private var headerMeta = NetworkMeta()
    @ObservationIgnored private var locations: [ColoLocation] = []

    /// /locations is a static list of every colo; fetch it once per process.
    private static var cachedLocations: [ColoLocation]?

    public init(config: SpeedTestConfig = .default) {
        self.config = config.sanitized()
    }

    public func start() {
        cancel()
        result = nil
        meta = NetworkMeta()
        fetchedMeta = NetworkMeta()
        headerMeta = NetworkMeta()
        downloadMbps = 0
        uploadMbps = 0
        latencyMs = 0
        downloadSamples = []
        uploadSamples = []
        runTask = Task { await run() }
    }

    /// Stops the current run immediately and returns to `.idle`.
    public func cancel() {
        runTask?.cancel()
        metadataTask?.cancel()
        eventTask?.cancel()
        runTask = nil
        metadataTask = nil
        eventTask = nil
        if isRunning { phase = .idle }
    }

    // MARK: - Run

    private enum Event: Sendable {
        case latency(Double)
        case download(Double)
        case upload(Double)
        case headerMeta(NetworkMeta)
    }

    private func run() async {
        let client = CloudflareClient(baseURL: config.baseURL)
        defer { client.invalidate() }
        phase = .connecting

        // Engine callbacks fire off the main actor. Funnel them through one
        // FIFO stream drained by one main-actor task, so ticks apply in the
        // order they were produced (a Task per tick can reorder under load).
        let (events, sink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        eventTask = Task { [weak self] in
            for await event in events {
                guard !Task.isCancelled, let self else { return }
                self.apply(event)
            }
        }
        defer { sink.finish() }

        // Metadata is decoration — colo name, ISP, map pin. Load it alongside
        // the test instead of in front of it, and never fail a run over it.
        metadataTask = Task { [weak self] in await self?.loadMetadata(client) }

        phase = .latency
        let idleProbe = await runLatencyProbes(client: client, count: config.idleLatencyProbeCount) { ms in
            sink.yield(.latency(ms))
        }
        guard !Task.isCancelled else { return }

        // Not one probe returned, so there is nothing to measure. The probe's
        // own URLError says why — offline, blocked, or timing out — which is
        // both more specific and more current than any pre-flight check.
        guard let idleLatency = idleProbe.summary else {
            metadataTask?.cancel()
            phase = .failed(idleProbe.error.map(TestFailure.init) ?? .unreachable)
            return
        }

        phase = .download
        async let downloadResult = runDownloadPhase(client: client, config: config) { meta in
            sink.yield(.headerMeta(meta))
        } onTick: { mbps, _ in
            sink.yield(.download(mbps))
        }
        async let downloadLoadedLatency = runLoadedLatencyProbes(client: client, duration: config.downloadDuration) { ms in
            sink.yield(.latency(ms))
        }
        let (download, dlLatency) = await (downloadResult, downloadLoadedLatency)
        guard !Task.isCancelled else { return }

        // Latency worked a moment ago, so a phase that moved no bytes at all
        // means the link died in between. Reporting 0 Mbps as a measurement
        // would look like a real (terrible) result rather than a failure.
        guard download.bytes > 0 else {
            phase = .failed(.interrupted)
            return
        }

        phase = .upload
        async let uploadResult = runUploadPhase(client: client, config: config) { mbps, _ in
            sink.yield(.upload(mbps))
        }
        async let uploadLoadedLatency = runLoadedLatencyProbes(client: client, duration: config.uploadDuration) { ms in
            sink.yield(.latency(ms))
        }
        let (upload, ulLatency) = await (uploadResult, uploadLoadedLatency)
        guard !Task.isCancelled else { return }

        guard upload.bytes > 0 else {
            phase = .failed(.interrupted)
            return
        }

        // Metadata has had the whole test to arrive and every call is capped
        // at `CloudflareClient.metadataTimeout`, so this is effectively free.
        await metadataTask?.value
        // Drain any ticks still queued so none lands after the final values.
        sink.finish()
        await eventTask?.value
        guard !Task.isCancelled else { return }

        result = TestResult(
            meta: meta,
            idleLatency: idleLatency,
            download: download,
            downloadLoadedLatency: dlLatency,
            upload: upload,
            uploadLoadedLatency: ulLatency
        )
        latencyMs = idleLatency.avgMs
        phase = .finished
    }

    private func apply(_ event: Event) {
        switch event {
        case .latency(let ms):
            latencyMs = ms
        case .download(let mbps):
            downloadMbps = mbps
            downloadSamples.append(mbps)
        case .upload(let mbps):
            uploadMbps = mbps
            uploadSamples.append(mbps)
        case .headerMeta(let header):
            headerMeta = header
            recomputeMeta()
        }
    }

    // MARK: - Metadata

    private func loadMetadata(_ client: CloudflareClient) async {
        async let trace = client.fetchTrace()
        async let info = client.fetchMetaInfo()
        #if os(tvOS)
        // tvOS shows no map, so the colo coordinate list is dead weight.
        let locations: [ColoLocation] = []
        #else
        let locations = await Self.locations(using: client)
        #endif
        var fetched = await trace
        fetched.merge(await info)

        guard !Task.isCancelled else { return }
        self.fetchedMeta = fetched
        self.locations = locations
        recomputeMeta()
    }

    private static func locations(using client: CloudflareClient) async -> [ColoLocation] {
        if let cachedLocations { return cachedLocations }
        let fetched = await client.fetchLocations()
        // Only cache a real answer; an empty list means the fetch failed.
        if !fetched.isEmpty { cachedLocations = fetched }
        return fetched
    }

    /// Fixed precedence: trace, then /meta, then response headers, then the
    /// /locations lookup to fill in coordinates and city for the colo.
    private func recomputeMeta() {
        var combined = fetchedMeta
        combined.merge(headerMeta)
        if let colo = combined.colo, let match = locations.first(where: { $0.iata == colo }) {
            combined.merge(NetworkMeta(city: match.city, country: match.cca2, latitude: match.lat, longitude: match.lon))
        }
        meta = combined
    }
}
