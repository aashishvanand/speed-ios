import Foundation

/// Orchestrates a full Cloudflare speed test run: idle latency, download
/// (with loaded latency), upload (with loaded latency). Emits progress via
/// an AsyncStream so SwiftUI views can observe it directly.
@MainActor
public final class SpeedTestRunner: ObservableObject {
    @Published public private(set) var phase: TestPhase = .idle
    @Published public private(set) var meta = NetworkMeta()
    @Published public private(set) var downloadMbps: Double = 0
    @Published public private(set) var uploadMbps: Double = 0
    @Published public private(set) var latencyMs: Double = 0
    @Published public private(set) var result: TestResult?

    private let config: SpeedTestConfig
    private var runTask: Task<Void, Never>?

    public init(config: SpeedTestConfig = .default) {
        self.config = config
    }

    public func start() {
        cancel()
        result = nil
        downloadMbps = 0
        uploadMbps = 0
        latencyMs = 0
        runTask = Task { await run() }
    }

    public func cancel() {
        runTask?.cancel()
        runTask = nil
    }

    private func run() async {
        let client = CloudflareClient(baseURL: config.baseURL)
        phase = .connecting

        let trace = await client.fetchTrace()
        meta.merge(trace)

        phase = .latency
        let idleLatency = await runLatencyProbes(client: client, count: config.idleLatencyProbeCount) { [weak self] ms in
            Task { @MainActor in self?.latencyMs = ms }
        }
        if Task.isCancelled { phase = .idle; return }

        phase = .download
        async let downloadResult = runDownloadPhase(client: client, config: config) { [weak self] mbps, _ in
            Task { @MainActor in self?.downloadMbps = mbps }
        }
        async let downloadLoadedLatency = runLoadedLatencyProbes(client: client, duration: config.downloadDuration) { [weak self] ms in
            Task { @MainActor in self?.latencyMs = ms }
        }
        let (download, dlLatency) = await (downloadResult, downloadLoadedLatency)
        if Task.isCancelled { phase = .idle; return }

        phase = .upload
        async let uploadResult = runUploadPhase(client: client, config: config) { [weak self] mbps, _ in
            Task { @MainActor in self?.uploadMbps = mbps }
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
        phase = .finished
    }
}
