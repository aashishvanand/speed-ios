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
    private let timing: Timing
    private let makeClient: @MainActor (SpeedTestConfig) -> CloudflareClient

    /// Engine timings that tests shrink. Production always uses `.default`.
    struct Timing: Sendable {
        /// Hard ceiling on the idle-latency batch, whatever the mix of
        /// successes and failures.
        var idleLatencyBudget: Duration = .seconds(15)
        /// How long a finished run waits for metadata still in flight before
        /// publishing without it. Metadata has had the whole test to arrive,
        /// so this only matters when something is stalled.
        var metadataGrace: Duration = .seconds(2)

        static let `default` = Timing()
    }

    // Everything belonging to the current run, cancelled together. Every run
    // gets an ID, and every state write checks it (and cancellation) first,
    // so a superseded or cancelled run can never write over a newer one or
    // drag the phase back to "running" after a cancel.
    @ObservationIgnored private var currentRunID = 0
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

    public convenience init(config: SpeedTestConfig = .default) {
        self.init(config: config, timing: .default, protocolClasses: nil)
    }

    /// Test hook: shorter timings, and a session routed through stub protocols.
    init(config: SpeedTestConfig, timing: Timing, protocolClasses: [AnyClass]?) {
        self.config = config.sanitized()
        self.timing = timing
        self.makeClient = { config in
            CloudflareClient(baseURL: config.baseURL, concurrency: config.concurrency, protocolClasses: protocolClasses)
        }
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
        // Flip to running synchronously, so the UI reflects the tap at once
        // and a second tap sees a run in progress.
        phase = .connecting
        let id = currentRunID
        runTask = Task { await run(id: id) }
    }

    /// Stops the current run immediately and returns to `.idle`.
    public func cancel() {
        currentRunID += 1
        runTask?.cancel()
        metadataTask?.cancel()
        eventTask?.cancel()
        runTask = nil
        metadataTask = nil
        eventTask = nil
        if isRunning { phase = .idle }
    }

    #if DEBUG
    /// Screenshot hook: puts the runner into a given state without any
    /// network traffic, so App Store screenshots show representative numbers
    /// and no real IP address. Compiled out of release builds.
    public func showDemoState(phase: TestPhase, result: TestResult?, downloadSamples: [Double], uploadSamples: [Double], latencyMs: Double) {
        cancel()
        self.result = result
        self.meta = result?.meta ?? NetworkMeta()
        self.downloadSamples = downloadSamples
        self.uploadSamples = uploadSamples
        self.downloadMbps = downloadSamples.last ?? 0
        self.uploadMbps = uploadSamples.last ?? 0
        self.latencyMs = latencyMs
        self.phase = phase
    }
    #endif

    /// True while `id` is still the run the UI is showing.
    private func isCurrent(_ id: Int) -> Bool {
        id == currentRunID && !Task.isCancelled
    }

    // MARK: - Run

    private enum Event: Sendable {
        case latency(Double)
        case download(Double)
        case upload(Double)
        case headerMeta(NetworkMeta)
    }

    private func run(id: Int) async {
        // Cancelled before it even started: touch nothing.
        guard isCurrent(id) else { return }
        let client = makeClient(config)
        defer { client.invalidate() }

        // Engine callbacks fire off the main actor. Funnel them through one
        // FIFO stream drained by one main-actor task, so ticks apply in the
        // order they were produced (a Task per tick can reorder under load).
        let (events, sink) = AsyncStream.makeStream(of: Event.self, bufferingPolicy: .unbounded)
        eventTask = Task { [weak self] in
            for await event in events {
                guard let self, self.isCurrent(id) else { return }
                self.apply(event)
            }
        }
        defer { sink.finish() }

        // Metadata is decoration — colo name, ISP, map pin. Load it alongside
        // the test instead of in front of it, and never fail a run over it.
        let metadataTask = Task { [weak self] () -> Void in await self?.loadMetadata(client, runID: id) }
        self.metadataTask = metadataTask
        defer { metadataTask.cancel() }

        phase = .latency
        let idleProbe = await runLatencyProbes(client: client, count: config.idleLatencyProbeCount, budget: timing.idleLatencyBudget) { ms in
            sink.yield(.latency(ms))
        }
        guard isCurrent(id) else { return }

        // Not one probe returned, so there is nothing to measure. The probe's
        // own error says why — offline, blocked, rejected, or timing out —
        // which is both more specific and more current than any pre-flight
        // check.
        guard let idleLatency = idleProbe.summary else {
            phase = .failed(idleProbe.failure ?? .unreachable)
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
        guard isCurrent(id) else { return }

        // Latency worked a moment ago, so a phase that moved no bytes at all
        // means the link died in between — or every request was refused.
        // Reporting 0 Mbps as a measurement would look like a real (terrible)
        // result rather than a failure.
        if let failure = Self.failure(for: download) {
            phase = .failed(failure)
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
        guard isCurrent(id) else { return }

        if let failure = Self.failure(for: upload) {
            phase = .failed(failure)
            return
        }

        // Publish with whatever metadata has landed. Anything still in flight
        // gets a short, real grace period, then is cancelled. (Awaiting a
        // task's value isn't itself cancellable, so the deadline cancels the
        // metadata task rather than the wait.)
        let grace = timing.metadataGrace
        let graceTimer = Task {
            try? await Task.sleep(for: grace)
            metadataTask.cancel()
        }
        await metadataTask.value
        graceTimer.cancel()
        // Drain any ticks still queued so none lands after the final values.
        sink.finish()
        await eventTask?.value
        guard isCurrent(id) else { return }

        result = TestResult(
            meta: meta,
            idleLatency: idleLatency,
            download: download.summary,
            downloadLoadedLatency: dlLatency,
            upload: upload.summary,
            uploadLoadedLatency: ulLatency
        )
        latencyMs = idleLatency.avgMs
        phase = .finished
    }

    /// Why a throughput phase can't stand as a measurement, or nil if it can.
    private static func failure(for outcome: PhaseOutcome) -> TestFailure? {
        guard outcome.summary.bytes == 0 else { return nil }
        if let status = outcome.lastRejectedStatus {
            return .rejected(statusCode: status)
        }
        return .interrupted
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

    private func loadMetadata(_ client: CloudflareClient, runID: Int) async {
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

        guard isCurrent(runID) else { return }
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
