import Foundation
import Testing
@testable import CFSpeedKit

@Suite("Config sanitizing")
struct ConfigSanitizingTests {
    @Test("Non-HTTPS and malformed base URLs fall back to the default endpoint")
    func enforcesHTTPS() {
        var config = SpeedTestConfig.default
        config.baseURL = URL(string: "http://speed.cloudflare.com")!
        #expect(config.sanitized().baseURL == SpeedTestConfig.default.baseURL)

        config.baseURL = URL(string: "file:///tmp/x")!
        #expect(config.sanitized().baseURL == SpeedTestConfig.default.baseURL)

        config.baseURL = URL(string: "https://example.com")!
        #expect(config.sanitized().baseURL == URL(string: "https://example.com")!)
    }

    @Test("Degenerate values are clamped into a runnable range")
    func clampsValues() {
        var config = SpeedTestConfig.default
        config.concurrency = 0
        config.sampleInterval = 0
        config.downloadDuration = -5
        config.uploadDuration = .nan
        config.idleLatencyProbeCount = 0
        let safe = config.sanitized()
        #expect(safe.concurrency == 1)
        #expect(safe.sampleInterval > 0)
        #expect(safe.downloadDuration >= 1)
        #expect(safe.uploadDuration == SpeedTestConfig.default.uploadDuration)
        #expect(safe.idleLatencyProbeCount == 1)
    }

    @Test("The default config passes through unchanged")
    func defaultUnchanged() {
        let d = SpeedTestConfig.default
        let s = d.sanitized()
        #expect(s.baseURL == d.baseURL)
        #expect(s.concurrency == d.concurrency)
        #expect(s.sampleInterval == d.sampleInterval)
        #expect(s.downloadDuration == d.downloadDuration)
    }
}

@Suite("Engine primitives")
struct EnginePrimitiveTests {
    @Test("ByteCounter is exact under heavy concurrent increments")
    func counterIsExact() async {
        let counter = ByteCounter()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    for _ in 0..<10_000 { counter.add(3) }
                }
            }
        }
        #expect(counter.snapshot().total == 8 * 10_000 * 3)
    }

    @Test("OneShot lets exactly one caller win")
    func oneShot() async {
        let flag = OneShot()
        let wins = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<50 { group.addTask { flag.claim() } }
            return await group.reduce(0) { $0 + ($1 ? 1 : 0) }
        }
        #expect(wins == 1)
    }

    @Test("URL builders produce the expected endpoints")
    func urls() {
        let client = CloudflareClient(baseURL: URL(string: "https://speed.cloudflare.com")!, measId: "abc")
        defer { client.invalidate() }
        #expect(client.downURL(bytes: 0).absoluteString == "https://speed.cloudflare.com/__down?bytes=0&measId=abc")
        #expect(client.upURL().absoluteString == "https://speed.cloudflare.com/__up?measId=abc")
    }

    @Test("Summary drops the ramp-up samples")
    func summaryDropsRampUp() {
        // 10 samples: the first 2 (20%) are slow-start and must not count.
        let samples: [Double] = [1, 1, 100, 100, 100, 100, 100, 100, 100, 100]
        let summary = summarize(totalBytes: 1, samples: samples, duration: 2)
        #expect(summary.p25Mbps == 100)
        #expect(summary.meanMbps == 100)
    }
}

@Suite("History storage codes")
struct HistoryCodeTests {
    @Test("Connection types persist as stable codes, not display labels")
    func stableCodes() {
        #expect(ConnectionType.wifi.rawValue == "wifi")
        #expect(ConnectionType.wiredEthernet.rawValue == "ethernet")
        #expect(ConnectionType.wifi.displayName == "Wi-Fi")
        #expect(ConnectionType(rawValue: "Wi-Fi") == nil)
    }
}
