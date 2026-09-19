import Foundation

public struct NetworkMeta: Sendable, Equatable {
    public var clientIP: String?
    public var colo: String?
    public var city: String?
    public var country: String?
    public var asn: String?
    public var latitude: Double?
    public var longitude: Double?

    public init(clientIP: String? = nil, colo: String? = nil, city: String? = nil, country: String? = nil, asn: String? = nil, latitude: Double? = nil, longitude: Double? = nil) {
        self.clientIP = clientIP
        self.colo = colo
        self.city = city
        self.country = country
        self.asn = asn
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
        latitude = latitude ?? other.latitude
        longitude = longitude ?? other.longitude
    }
}

public struct LatencySummary: Sendable, Equatable {
    public var jitterMs: Double
    public var minMs: Double
    public var avgMs: Double
    public var maxMs: Double
    public var samples: [Double]

    public static let failed = LatencySummary(jitterMs: 0, minMs: 0, avgMs: 0, maxMs: 0, samples: [])

    public init(jitterMs: Double, minMs: Double, avgMs: Double, maxMs: Double, samples: [Double]) {
        self.jitterMs = jitterMs
        self.minMs = minMs
        self.avgMs = avgMs
        self.maxMs = maxMs
        self.samples = samples
    }

    public init?(samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let min = sorted.first!
        let max = sorted.last!
        let avg = samples.reduce(0, +) / Double(samples.count)
        var jitterSum = 0.0
        for i in 1..<samples.count {
            jitterSum += abs(samples[i] - samples[i - 1])
        }
        let jitter = samples.count > 1 ? jitterSum / Double(samples.count - 1) : 0
        self.init(jitterMs: jitter, minMs: min, avgMs: avg, maxMs: max, samples: samples)
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
    case great = "Great"
    case good = "Good"
    case fair = "Fair"
    case poor = "Poor"
}

/// Rough per-use-case quality estimate derived from measured throughput and
/// idle latency/jitter — directionally similar to, but not an exact copy of,
/// Cloudflare's own "Network Quality Score" categories.
public struct NetworkQuality: Sendable, Equatable {
    public var videoStreaming: QualityGrade
    public var onlineGaming: QualityGrade
    public var videoChatting: QualityGrade

    public init(download: Double, upload: Double, latencyMs: Double, jitterMs: Double) {
        videoStreaming = download >= 25 ? .great : download >= 10 ? .good : download >= 3 ? .fair : .poor
        onlineGaming = (latencyMs < 50 && jitterMs < 30) ? .great : (latencyMs < 100 && jitterMs < 50) ? .good : latencyMs < 200 ? .fair : .poor
        videoChatting = (upload >= 3 && latencyMs < 150) ? .great : (upload >= 1 && latencyMs < 300) ? .good : upload >= 0.5 ? .fair : .poor
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
        self.quality = NetworkQuality(
            download: download.meanMbps,
            upload: upload.meanMbps,
            latencyMs: idleLatency.avgMs,
            jitterMs: idleLatency.jitterMs
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
