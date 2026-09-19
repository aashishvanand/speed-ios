import Foundation

/// Orchestrates a full Cloudflare speed test run: idle latency, download
/// (with loaded latency), upload (with loaded latency). Publishes progress
/// directly so SwiftUI views can observe it via @StateObject/@ObservedObject.
@MainActor
public final class SpeedTestRunner: ObservableObject {
    @Published public private(set) var phase: TestPhase = .idle
    @Published public private(set) var meta = NetworkMeta()
    @Published public private(set) var downloadMbps: Double = 0
    @Published public private(set) var uploadMbps: Double = 0
    @Published public private(set) var latencyMs: Double = 0
    @Published public private(set) var result: TestResult?

    /// Instantaneous Mbps samples (one per `sampleInterval` tick) for the
    /// currently running or most recently completed phase — used to draw the
    /// live throughput graph behind the hero number.
    @Published public private(set) var downloadSamples: [Double] = []
    @Published public private(set) var uploadSamples: [Double] = []

    private let config: SpeedTestConfig
    private var runTask: Task<Void, Never>?

    public init(config: SpeedTestConfig = .default) {
        self.config = config
    }

    public func start() {
        cancel()
        result = nil
        meta = NetworkMeta()
        downloadMbps = 0
        uploadMbps = 0
        latencyMs = 0
        downloadSamples = []
        uploadSamples = []
        runTask = Task { await run() }
    }

    public func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    private func run() async {
        let client = CloudflareClient(baseURL: config.baseURL)
        phase = .connecting

        async let locationsTask = client.fetchLocations()
        async let metaInfoTask = client.fetchMetaInfo()
        let trace = await client.fetchTrace()
        meta.merge(trace)
        meta.merge(await metaInfoTask)
        let locations = await locationsTask
        resolveColoLocation(locations: locations)

        phase = .latency
        let idleLatency = await runLatencyProbes(client: client, count: config.idleLatencyProbeCount) { [weak self] ms in
            Task { @MainActor in self?.latencyMs = ms }
        }
        if Task.isCancelled { phase = .idle; return }

        phase = .download
        async let downloadResult = runDownloadPhase(client: client, config: config) { [weak self] meta in
            Task { @MainActor in
                self?.meta.merge(meta)
                self?.resolveColoLocation(locations: locations)
            }
        } onTick: { [weak self] mbps, _ in
            Task { @MainActor in
                self?.downloadMbps = mbps
                self?.downloadSamples.append(mbps)
            }
        }
        async let downloadLoadedLatency = runLoadedLatencyProbes(client: client, duration: config.downloadDuration) { [weak self] ms in
            Task { @MainActor in self?.latencyMs = ms }
        }
        let (download, dlLatency) = await (downloadResult, downloadLoadedLatency)
        if Task.isCancelled { phase = .idle; return }

        phase = .upload
        async let uploadResult = runUploadPhase(client: client, config: config) { [weak self] mbps, _ in
            Task { @MainActor in
                self?.uploadMbps = mbps
                self?.uploadSamples.append(mbps)
            }
        }
        async let uploadLoadedLatency = runLoadedLatencyProbes(client: client, duration: config.uploadDuration) { [weak self] ms in
            Task { @MainActor in self?.latencyMs = ms }
        }
        let (upload, ulLatency) = await (uploadResult, uploadLoadedLatency)
        if Task.isCancelled { phase = .idle; return }

        let finalResult = TestResult(
            meta: meta,
            idleLatency: idleLatency,
            download: download,
            downloadLoadedLatency: dlLatency,
            upload: upload,
            uploadLoadedLatency: ulLatency
        )
        result = finalResult
        latencyMs = idleLatency.avgMs
        phase = .finished
    }

    /// Looks up the current colo's coordinates/city from the /locations list
    /// (cf-meta-city is frequently absent, so this is the reliable source).
    private func resolveColoLocation(locations: [ColoLocation]) {
        guard let colo = meta.colo, let match = locations.first(where: { $0.iata == colo }) else { return }
        meta.merge(NetworkMeta(city: match.city, country: match.cca2, latitude: match.lat, longitude: match.lon))
    }
}
