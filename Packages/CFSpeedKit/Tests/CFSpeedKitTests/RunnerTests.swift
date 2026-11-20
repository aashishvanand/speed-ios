import Foundation
import os
import Testing
@testable import CFSpeedKit

@MainActor
@Suite("Runner lifecycle")
struct RunnerLifecycleTests {
    private func makeRunner(_ server: StubServer = StubServer()) -> (SpeedTestRunner, URL) {
        let baseURL = server.install()
        let runner = SpeedTestRunner(config: .stub(baseURL), timing: .stub, protocolClasses: [StubProtocol.self])
        return (runner, baseURL)
    }

    @Test("A normal run finishes with a result and metadata")
    func completes() async {
        let (runner, url) = makeRunner()
        defer { StubServer.uninstall(url) }
        runner.start()
        #expect(await waitUntil { runner.phase == .finished })
        let result = runner.result
        #expect((result?.download.bytes ?? 0) > 0)
        #expect((result?.upload.bytes ?? 0) > 0)
        #expect(result?.meta.colo == "SFO")
        #expect(result?.meta.ispName == "Stub ISP")
    }

    @Test("Cancelling immediately returns to idle and stays there")
    func cancelImmediately() async throws {
        let (runner, url) = makeRunner()
        defer { StubServer.uninstall(url) }
        runner.start()
        runner.cancel()
        #expect(runner.phase == .idle)
        // Give the cancelled task every chance to (wrongly) write a phase.
        try await Task.sleep(for: .milliseconds(500))
        #expect(runner.phase == .idle)
        #expect(!runner.isRunning)
        #expect(runner.result == nil)
    }

    @Test("Cancelling mid-latency returns to idle and stays there")
    func cancelDuringLatency() async throws {
        var server = StubServer()
        server.probe = .respond(status: 200, delay: 0.2)
        let (runner, url) = makeRunner(server)
        defer { StubServer.uninstall(url) }
        runner.start()
        #expect(await waitUntil { runner.phase == .latency })
        runner.cancel()
        try await Task.sleep(for: .milliseconds(800))
        #expect(runner.phase == .idle)
        #expect(runner.latencyMs == 0 || !runner.isRunning)
    }

    @Test("Starting twice runs once, and the stale run can't clobber the new one")
    func startTwice() async throws {
        var server = StubServer()
        server.meta = .respond(status: 200, body: Data(#"{"asOrganization":"Second Run ISP","colo":{"iata":"AAA"}}"#.utf8), delay: 0.2)
        server.trace = .respond(status: 404)
        let (runner, url) = makeRunner(server)
        defer { StubServer.uninstall(url) }
        runner.start()
        runner.start()
        #expect(runner.isRunning)
        #expect(await waitUntil { runner.phase == .finished })
        #expect(runner.result?.meta.ispName == "Second Run ISP")
        // Nothing from the first run arrives afterwards.
        let result = runner.result
        try await Task.sleep(for: .milliseconds(300))
        #expect(runner.result == result)
        #expect(runner.phase == .finished)
    }

    @Test("Stalled metadata doesn't hold up the result")
    func stalledMetadata() async {
        var server = StubServer()
        server.meta = .stall
        server.trace = .stall
        server.locations = .stall
        let (runner, url) = makeRunner(server)
        defer { StubServer.uninstall(url) }
        let started = ContinuousClock.now
        runner.start()
        #expect(await waitUntil(timeout: 8) { runner.phase == .finished })
        let elapsed = (ContinuousClock.now - started).timeInterval
        // 1 s + 1 s of transfer, a few probes, and the 0.3 s grace — nowhere
        // near the 8 s metadata timeout.
        #expect(elapsed < 4.5, "took \(elapsed)s")
        // Header metadata from the download still made it.
        #expect(runner.result?.meta.colo == "SFO")
    }
}

@MainActor
@Suite("HTTP error responses")
struct HTTPErrorTests {
    private func run(_ server: StubServer) async -> TestPhase {
        let baseURL = server.install()
        defer { StubServer.uninstall(baseURL) }
        let runner = SpeedTestRunner(config: .stub(baseURL), timing: .stub, protocolClasses: [StubProtocol.self])
        runner.start()
        _ = await waitUntil { !runner.isRunning }
        #expect(runner.result == nil)
        return runner.phase
    }

    @Test("Rejected latency probes fail the run with the status", arguments: [403, 429, 500])
    func probes(status: Int) async {
        var server = StubServer()
        server.probe = .respond(status: status)
        #expect(await run(server) == .failed(.rejected(statusCode: status)))
    }

    @Test("Rejected downloads fail the run instead of reporting ~0 Mbps", arguments: [403, 429, 500])
    func downloads(status: Int) async {
        var server = StubServer()
        server.download = .respond(status: status, body: Data(count: 4096), delay: 0.01)
        #expect(await run(server) == .failed(.rejected(statusCode: status)))
    }

    @Test("Rejected uploads fail the run instead of reporting ~0 Mbps", arguments: [403, 429, 500])
    func uploads(status: Int) async {
        var server = StubServer()
        server.upload = .respond(status: status, delay: 0.01)
        #expect(await run(server) == .failed(.rejected(statusCode: status)))
    }
}

@Suite("Latency deadlines")
struct LatencyDeadlineTests {
    @Test("A stalled idle probe can't run past the batch budget")
    func idleBudget() async {
        var server = StubServer()
        server.probe = .stall
        let baseURL = server.install()
        defer { StubServer.uninstall(baseURL) }
        let client = CloudflareClient(baseURL: baseURL, protocolClasses: [StubProtocol.self])
        defer { client.invalidate() }

        let started = ContinuousClock.now
        let result = await runLatencyProbes(client: client, count: 10, budget: .seconds(1)) { _ in }
        let elapsed = (ContinuousClock.now - started).timeInterval
        // Without the budget, the stalled probes would each wait the 5 s probe
        // timeout. 3.5 s still catches that while tolerating a CI simulator
        // that freezes for a couple of seconds.
        #expect(elapsed < 3.5, "took \(elapsed)s")
        #expect(result.summary == nil)
        #expect(result.failure == .unreachable)
    }

    @Test("The idle batch doesn't sleep after its final probe")
    func noTrailingSleep() async throws {
        let baseURL = StubServer().install()
        defer { StubServer.uninstall(baseURL) }
        let client = CloudflareClient(baseURL: baseURL, protocolClasses: [StubProtocol.self])
        defer { client.invalidate() }

        // Time from the final sample to the return, not the whole call: the
        // probe itself (connection setup on a busy CI simulator) can take far
        // longer than the 100 ms pause this is checking for.
        let lastSample = OSAllocatedUnfairLock<ContinuousClock.Instant?>(initialState: nil)
        let result = await runLatencyProbes(client: client, count: 1, budget: .seconds(5)) { _ in
            lastSample.withLock { $0 = .now }
        }
        let returned = ContinuousClock.now
        #expect(result.summary?.samples.count == 1)
        let sampled = try #require(lastSample.withLock { $0 })
        let tail = (returned - sampled).timeInterval
        #expect(tail < 0.08, "returned \(tail)s after the last sample")
    }

    @Test("Loaded probes end with their phase, even mid-probe")
    func loadedDeadline() async {
        var server = StubServer()
        server.probe = .stall
        let baseURL = server.install()
        defer { StubServer.uninstall(baseURL) }
        let client = CloudflareClient(baseURL: baseURL, protocolClasses: [StubProtocol.self])
        defer { client.invalidate() }

        let started = ContinuousClock.now
        let summary = await runLoadedLatencyProbes(client: client, duration: 1) { _ in }
        let elapsed = (ContinuousClock.now - started).timeInterval
        #expect(summary == nil)
        // Without the phase deadline, the stalled probe would wait the 5 s
        // probe timeout; 3.5 s leaves room for a sluggish CI simulator.
        #expect(elapsed < 3.5, "took \(elapsed)s")
    }
}

@Suite("Throughput sampling")
struct SamplingTests {
    @Test("On-time ticks advance by one interval")
    func onTime() {
        #expect(abs(nextTickOffset(after: 0.4, now: 0.41, interval: 0.2, end: 8) - 0.6) < 1e-9)
    }

    @Test("A late wakeup skips to the next tick still in the future")
    func lateWakeup() {
        // Woke at 1.05 s for the tick due at 0.4 s: 0.6…1.0 are all overdue.
        let next = nextTickOffset(after: 0.4, now: 1.05, interval: 0.2, end: 8)
        #expect(abs(next - 1.2) < 1e-9)
        #expect(next > 1.05)
    }

    @Test("Ticks never pass the end of the phase")
    func clampsToEnd() {
        #expect(nextTickOffset(after: 7.9, now: 7.95, interval: 0.2, end: 8) == 8)
        #expect(nextTickOffset(after: 7.0, now: 9.0, interval: 0.2, end: 8) == 8)
    }

    @Test("Ramp-up is at least 1 s, 20% of long phases, and at most half")
    func rampWindow() {
        #expect(rampUpSeconds(forDuration: 3) == 1)
        #expect(rampUpSeconds(forDuration: 8) == 1.6)
        #expect(rampUpSeconds(forDuration: 1) == 0.5)
    }

    @Test("A short phase drops a full second of slow start")
    func shortPhaseRampUp() {
        // 3 s at 0.2 s ticks: the first 5 samples (0…1 s) are slow start.
        let samples = (0..<15).map { i in
            ThroughputSample(start: Double(i) * 0.2, end: Double(i + 1) * 0.2, mbps: i < 5 ? 1 : 100)
        }
        let summary = summarize(totalBytes: 1, samples: samples, duration: 3)
        #expect(summary.p25Mbps == 100)
        #expect(summary.meanMbps == 100)
    }

    @Test("Ramp-up follows timestamps, not sample counts")
    func timestampBased() {
        // A late wakeup produced one long sample covering 0.2…1.4 s; it
        // started inside the ramp, so it goes.
        let samples = [
            ThroughputSample(start: 0, end: 0.2, mbps: 1),
            ThroughputSample(start: 0.2, end: 1.4, mbps: 5),
            ThroughputSample(start: 1.4, end: 1.6, mbps: 100),
            ThroughputSample(start: 1.6, end: 1.8, mbps: 100),
        ]
        let summary = summarize(totalBytes: 1, samples: samples, duration: 3)
        #expect(summary.meanMbps == 100)
    }
}

@Suite("Speed formatting")
struct SpeedFormatTests {
    @Test("Precision scales with magnitude", arguments: [
        (0.0, "0.00 Mbps"),
        (0.42, "0.42 Mbps"),
        (0.996, "1.0 Mbps"),
        (4.24, "4.2 Mbps"),
        (42.4, "42 Mbps"),
        (420, "420 Mbps"),
        (999.4, "999 Mbps"),
        (999.7, "1.00 Gbps"),
        (1234, "1.23 Gbps"),
        (12_345, "12.3 Gbps"),
        (-3, "0.00 Mbps"),
    ])
    func formats(mbps: Double, expected: String) {
        #expect(SpeedFormat.text(mbps, locale: Locale(identifier: "en_US")) == expected)
    }

    @Test func followsTheRegionDecimalSeparator() {
        let germany = Locale(identifier: "de_DE")
        #expect(SpeedFormat.text(4.24, locale: germany) == "4,2 Mbps")
        #expect(SpeedFormat.text(1234, locale: germany) == "1,23 Gbps")
        #expect(SpeedFormat.milliseconds(1.64, fractionDigits: 1, locale: germany) == "1,6 ms")
    }
}

@Suite("Download request sizing")
struct DownloadRequestSizeTests {
    let floor = 25_000_000

    @Test func growsToAboutOneSecondOfTransfer() {
        // 25 MB in 0.1 s is 250 MB/s, so the next request asks for ~250 MB.
        let next = nextDownloadRequestSize(requested: floor, received: 25_000_000, elapsed: 0.1, floor: floor)
        #expect(next == 250_000_000)
    }

    @Test func neverDropsBelowTheConfiguredSize() {
        let next = nextDownloadRequestSize(requested: floor, received: 25_000_000, elapsed: 5, floor: floor)
        #expect(next == floor)
    }

    @Test func shrinksBackWhenTheLinkSlows() {
        let next = nextDownloadRequestSize(requested: 250_000_000, received: 250_000_000, elapsed: 5, floor: floor)
        #expect(next == 50_000_000)
    }

    @Test func capsAtTheMaximum() {
        let next = nextDownloadRequestSize(requested: floor, received: 25_000_000, elapsed: 0.000_001, floor: floor)
        #expect(next == SpeedTestConfig.maxDownloadBytesPerRequest)
    }

    @Test func ignoresAShortBody() {
        let next = nextDownloadRequestSize(requested: floor, received: 64 * 1024, elapsed: 0.001, floor: floor)
        #expect(next == floor)
    }
}
