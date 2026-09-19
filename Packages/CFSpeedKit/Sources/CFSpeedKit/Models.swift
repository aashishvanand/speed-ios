import Foundation

public struct NetworkMeta: Sendable, Equatable {
    public var clientIP: String?
    public var colo: String?
    public var city: String?
    public var country: String?
    public var asn: String?
    public var ispName: String?
    public var latitude: Double?
    public var longitude: Double?

    public init(clientIP: String? = nil, colo: String? = nil, city: String? = nil, country: String? = nil, asn: String? = nil, ispName: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.clientIP = clientIP
        self.colo = colo
        self.city = city
        self.country = country
        self.asn = asn
        self.ispName = ispName
        self.latitude = latitude
        self.longitude = longitude
    }

    public var isEmpty: Bool {
        clientIP == nil && colo == nil && city == nil && country == nil && asn == nil
    }

    mutating func merge(_ other: NetworkMeta) {
        clientIP = clientIP ?? other.clientIP
        colo = colo ?? other.colo
        city = city ?? other.city
        country = country ?? other.country
        asn = asn ?? other.asn
        ispName = ispName ?? other.ispName
        latitude = latitude ?? other.latitude
        longitude = longitude ?? other.longitude
    }
}

public struct LatencySummary: Sendable, Equatable {
    public var jitterMs: Double
    public var minMs: Double
    public var avgMs: Double
    public var medianMs: Double
    public var maxMs: Double
    public var samples: [Double]

    public static let failed = LatencySummary(jitterMs: 0, minMs: 0, avgMs: 0, medianMs: 0, maxMs: 0, samples: [])

    public init(jitterMs: Double, minMs: Double, avgMs: Double, medianMs: Double, maxMs: Double, samples: [Double]) {
        self.jitterMs = jitterMs
        self.minMs = minMs
        self.avgMs = avgMs
        self.medianMs = medianMs
        self.maxMs = maxMs
        self.samples = samples
    }

    public init?(samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let min = sorted.first!
        let max = sorted.last!
        let avg = samples.reduce(0, +) / Double(samples.count)
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        var jitterSum = 0.0
        for i in 1..<samples.count {
            jitterSum += abs(samples[i] - samples[i - 1])
        }
        let jitter = samples.count > 1 ? jitterSum / Double(samples.count - 1) : 0
        self.init(jitterMs: jitter, minMs: min, avgMs: avg, medianMs: median, maxMs: max, samples: samples)
    }
}

public struct ThroughputSummary: Sendable, Equatable {
    public var bytes: UInt64
    public var durationSeconds: Double
    public var meanMbps: Double
    public var medianMbps: Double
    public var p25Mbps: Double
    public var p75Mbps: Double
    public var p90Mbps: Double

    public static let zero = ThroughputSummary(bytes: 0, durationSeconds: 0, meanMbps: 0, medianMbps: 0, p25Mbps: 0, p75Mbps: 0, p90Mbps: 0)

    public init(bytes: UInt64, durationSeconds: Double, meanMbps: Double, medianMbps: Double, p25Mbps: Double, p75Mbps: Double, p90Mbps: Double) {
        self.bytes = bytes
        self.durationSeconds = durationSeconds
        self.meanMbps = meanMbps
        self.medianMbps = medianMbps
        self.p25Mbps = p25Mbps
        self.p75Mbps = p75Mbps
        self.p90Mbps = p90Mbps
    }
}

public enum TestPhase: Sendable, Equatable {
    case idle
    case connecting
    case latency
    case download
    case upload
    case finished
    case failed(String)
}

public enum QualityGrade: String, Sendable, Equatable {
    case bad = "Bad"
    case poor = "Poor"
    case average = "Average"
    case good = "Good"
    case great = "Great"
}

/// Step function mapping a value to one of `values.count` buckets via
/// ascending `thresholds` (`thresholds.count == values.count - 1`).
/// Direct port of scaleThreshold from github.com/cloudflare/speedtest.
private func scaleThreshold(_ thresholds: [Double], _ values: [Double]) -> (Double) -> Double {
    { value in
        var i = 0
        while i < thresholds.count && value >= thresholds[i] { i += 1 }
        return values[i]
    }
}

/// Cloudflare's published AIM (Aggregated Internet Measurement) scoring:
/// each raw metric is converted to points via threshold tables, the points
/// for each experience are summed, and the sum is classified bad...great.
/// Thresholds and weights are a direct port of the scoring tables in
/// github.com/cloudflare/speedtest (src/config/internalConfig.ts), which is
/// the actual engine behind speed.cloudflare.com's own quality score.
public struct NetworkQuality: Sendable, Equatable {
    public var videoStreaming: QualityGrade
    public var onlineGaming: QualityGrade
    public var videoChatting: QualityGrade

    /// - Parameters:
    ///   - download: p90 download bandwidth in Mbps.
    ///   - latencyMs: unloaded (idle) latency.
    ///   - jitterMs: unloaded (idle) jitter.
    ///   - loadedLatencyIncreaseMs: max(loaded download latency, loaded upload latency) − unloaded latency.
    ///   - packetLoss: fraction 0...1; pass 0 when unmeasured (matches the JS engine's own fallback).
    ///
    /// Note: none of Cloudflare's three published experiences (streaming,
    /// gaming, rtc) factor in upload bandwidth at all — only download does,
    /// and only for streaming. That's their real scoring table, not an
    /// omission here.
    public init(download: Double, latencyMs: Double, jitterMs: Double, loadedLatencyIncreaseMs: Double, packetLoss: Double = 0) {
        let packetLossScore = scaleThreshold([0.01, 0.05, 0.25, 0.5], [10, 5, 0, -10, -20])(packetLoss)
        let latencyScore = scaleThreshold([10, 20, 50, 100, 500], [20, 10, 5, 0, -10, -20])(latencyMs)
        let loadedLatencyIncreaseScore = scaleThreshold([10, 20, 50, 100, 500], [20, 10, 5, 0, -10, -20])(loadedLatencyIncreaseMs)
        let jitterScore = scaleThreshold([10, 20, 100, 500], [10, 5, 0, -10, -20])(jitterMs)
        let downloadScore = scaleThreshold([1, 10, 50, 100], [0, 5, 10, 20, 30])(download)

        func classify(_ points: [Double], thresholds: [Double]) -> QualityGrade {
            let sum = max(0, points.reduce(0, +))
            let idx = Int(scaleThreshold(thresholds, [0, 1, 2, 3, 4])(sum))
            return [.bad, .poor, .average, .good, .great][idx]
        }

        videoStreaming = classify(
            [latencyScore, packetLossScore, downloadScore, loadedLatencyIncreaseScore],
            thresholds: [15, 20, 40, 60]
        )
        onlineGaming = classify(
            [latencyScore, packetLossScore, loadedLatencyIncreaseScore],
            thresholds: [5, 15, 25, 30]
        )
        videoChatting = classify(
            [latencyScore, jitterScore, packetLossScore, loadedLatencyIncreaseScore],
            thresholds: [5, 15, 25, 40]
        )
    }
}

public struct TestResult: Sendable, Equatable {
    public var meta: NetworkMeta
    public var idleLatency: LatencySummary
    public var download: ThroughputSummary
    public var downloadLoadedLatency: LatencySummary
    public var upload: ThroughputSummary
    public var uploadLoadedLatency: LatencySummary
    public var quality: NetworkQuality

    public init(meta: NetworkMeta, idleLatency: LatencySummary, download: ThroughputSummary, downloadLoadedLatency: LatencySummary, upload: ThroughputSummary, uploadLoadedLatency: LatencySummary) {
        self.meta = meta
        self.idleLatency = idleLatency
        self.download = download
        self.downloadLoadedLatency = downloadLoadedLatency
        self.upload = upload
        self.uploadLoadedLatency = uploadLoadedLatency
        let loadedLatencyIncrease = max(downloadLoadedLatency.medianMs, uploadLoadedLatency.medianMs) - idleLatency.medianMs
        self.quality = NetworkQuality(
            download: download.p90Mbps,
            latencyMs: idleLatency.medianMs,
            jitterMs: idleLatency.jitterMs,
            loadedLatencyIncreaseMs: max(0, loadedLatencyIncrease)
        )
    }
}

public enum SpeedTestEvent: Sendable, Equatable {
    case phaseChanged(TestPhase)
    case metaUpdated(NetworkMeta)
    case throughputTick(phase: TestPhase, mbpsInstant: Double, bytesTotal: UInt64)
    case latencyTick(phase: TestPhase, ms: Double)
    case finished(TestResult)
}

public struct SpeedTestConfig: Sendable {
    public var baseURL: URL
    public var concurrency: Int
    public var downloadDuration: TimeInterval
    public var uploadDuration: TimeInterval
    public var downloadBytesPerRequest: Int
    public var uploadBytesPerRequest: Int
    public var idleLatencyProbeCount: Int
    public var sampleInterval: TimeInterval

    public static let `default` = SpeedTestConfig(
        baseURL: URL(string: "https://speed.cloudflare.com")!,
        concurrency: 6,
        downloadDuration: 8,
        uploadDuration: 8,
        downloadBytesPerRequest: 25_000_000,
        uploadBytesPerRequest: 5_000_000,
        idleLatencyProbeCount: 10,
        sampleInterval: 0.2
    )

    public init(baseURL: URL, concurrency: Int, downloadDuration: TimeInterval, uploadDuration: TimeInterval, downloadBytesPerRequest: Int, uploadBytesPerRequest: Int, idleLatencyProbeCount: Int, sampleInterval: TimeInterval) {
        self.baseURL = baseURL
        self.concurrency = concurrency
        self.downloadDuration = downloadDuration
        self.uploadDuration = uploadDuration
        self.downloadBytesPerRequest = downloadBytesPerRequest
        self.uploadBytesPerRequest = uploadBytesPerRequest
        self.idleLatencyProbeCount = idleLatencyProbeCount
        self.sampleInterval = sampleInterval
    }
}
