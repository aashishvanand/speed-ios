import Foundation

/// Where a test ran: the client's public address and network, and the
/// Cloudflare data center ("colo") that served it.
///
/// Assembled from several best-effort sources (response headers,
/// `/cdn-cgi/trace`, `/meta`, `/locations`), so any field may be missing.
public struct NetworkMeta: Sendable, Equatable {
    public var clientIP: String?
    /// IATA-style code of the serving data center, e.g. "SIN".
    public var colo: String?
    /// City of the serving data center.
    public var city: String?
    /// ISO 3166-1 alpha-2 country code.
    public var country: String?
    /// The client's autonomous system number, without the "AS" prefix.
    public var asn: String?
    /// The organization that owns `asn`, typically the ISP.
    public var ispName: String?
    /// Coordinates of the serving data center, for the map.
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

    /// Fills each missing field from `other`; fields already set win.
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

/// Statistics over a batch of round-trip latency probes, in milliseconds.
public struct LatencySummary: Sendable, Equatable {
    /// Mean absolute difference between consecutive samples, in the order
    /// they were taken (the definition speed.cloudflare.com uses). `nil` with
    /// fewer than two samples: one probe says nothing about variation, and
    /// 0 ms would read (and score) as a perfectly stable link.
    public var jitterMs: Double?
    public var minMs: Double
    public var avgMs: Double
    public var medianMs: Double
    public var maxMs: Double
    /// Raw samples in the order they were taken.
    public var samples: [Double]

    public init(jitterMs: Double?, minMs: Double, avgMs: Double, medianMs: Double, maxMs: Double, samples: [Double]) {
        self.jitterMs = jitterMs
        self.minMs = minMs
        self.avgMs = avgMs
        self.medianMs = medianMs
        self.maxMs = maxMs
        self.samples = samples
    }

    /// Summarizes `samples`, or returns nil when there are none, so callers
    /// can't mistake "unmeasured" for a real 0 ms.
    public init?(samples: [Double]) {
        guard !samples.isEmpty else { return nil }
        let sorted = samples.sorted()
        let min = sorted.first!
        let max = sorted.last!
        let avg = samples.reduce(0, +) / Double(samples.count)
        let mid = sorted.count / 2
        let median = sorted.count % 2 == 0 ? (sorted[mid - 1] + sorted[mid]) / 2 : sorted[mid]
        var jitter: Double?
        if samples.count > 1 {
            var jitterSum = 0.0
            for i in 1..<samples.count {
                jitterSum += abs(samples[i] - samples[i - 1])
            }
            jitter = jitterSum / Double(samples.count - 1)
        }
        self.init(jitterMs: jitter, minMs: min, avgMs: avg, medianMs: median, maxMs: max, samples: samples)
    }
}

/// Result of one throughput phase. The percentile figures cover only the
/// steady-state samples, after ramp-up is discarded (see `summarize`).
/// The app reports `p90Mbps` as the headline number, as speed.cloudflare.com
/// does.
public struct ThroughputSummary: Sendable, Equatable {
    /// Every byte moved during the phase, ramp-up included.
    public var bytes: UInt64
    public var durationSeconds: Double
    public var meanMbps: Double
    public var medianMbps: Double
    public var p25Mbps: Double
    public var p75Mbps: Double
    public var p90Mbps: Double

    /// A phase that moved nothing.
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

/// Where a run is. A run moves forward through these in order and ends in
/// `.finished` or `.failed`; `cancel()` returns it to `.idle`.
public enum TestPhase: Sendable, Equatable {
    case idle
    /// Set synchronously on `start()`, before the first request goes out.
    case connecting
    case latency
    case download
    case upload
    case finished
    case failed(TestFailure)
}

/// Why a run couldn't produce a result, derived from the `URLError` the
/// request actually failed with.
///
/// This is deliberately error-driven rather than reachability-driven: Apple
/// deprecated the pre-flight reachability APIs because a route says nothing
/// about whether a given host answers, and any check is racy against the
/// request that follows it. The failing request itself is both the
/// connectivity check and the explanation.
public enum TestFailure: Sendable, Equatable {
    /// No network path at all — airplane mode, Wi-Fi off, no cellular.
    case offline
    /// A path exists but policy forbids this transfer: cellular data off for
    /// the app, Low Data Mode, or roaming disabled.
    case dataNotAllowed
    /// Connected, but the edge never answered — captive portal, DNS
    /// blackhole, blocked endpoint, or a timeout.
    case unreachable
    /// The connection worked and then died partway through a measurement.
    case interrupted
    /// The edge answered, but with an HTTP error — typically 429 (rate
    /// limited) or 403 (blocked by a network filter).
    case rejected(statusCode: Int)
    /// Anything else, carrying the system's description.
    case unknown(String)

    public init(_ error: URLError) {
        switch error.code {
        case .notConnectedToInternet:
            self = .offline
        case .dataNotAllowed, .internationalRoamingOff, .callIsActive:
            self = .dataNotAllowed
        case .networkConnectionLost:
            self = .interrupted
        case .timedOut, .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
             .secureConnectionFailed, .serverCertificateUntrusted,
             .appTransportSecurityRequiresSecureConnection, .resourceUnavailable,
             .badServerResponse:
            self = .unreachable
        default:
            self = .unknown(error.localizedDescription)
        }
    }

    /// Classifies whatever a latency probe threw.
    init(probeError error: Error) {
        switch error {
        case let status as HTTPStatusError: self = .rejected(statusCode: status.statusCode)
        case let urlError as URLError: self.init(urlError)
        default: self = .unknown(error.localizedDescription)
        }
    }

    /// True when retrying inside the same run can't change the outcome, so
    /// the run should stop rather than spend its whole probe budget.
    /// Timeouts and dropped connections are excluded — those are worth a retry.
    var isTerminal: Bool {
        switch self {
        case .offline, .dataNotAllowed: return true
        case .unreachable, .interrupted, .rejected, .unknown: return false
        }
    }

    /// True when it's worth starting a new run by itself as soon as the
    /// network comes back. Only for failures the network returning can fix:
    /// retrying a 429 at once makes the rate limit worse, and a blocked or
    /// refused test will just fail again.
    public var allowsAutomaticRetry: Bool {
        switch self {
        case .offline, .interrupted: return true
        case .dataNotAllowed, .unreachable, .rejected, .unknown: return false
        }
    }

    public var title: String {
        switch self {
        case .offline: return "No Internet Connection"
        case .dataNotAllowed: return "Data Not Allowed"
        case .unreachable: return "Can't Reach Cloudflare"
        case .interrupted: return "Connection Lost"
        case .rejected: return "Test Refused"
        case .unknown: return "Test Failed"
        }
    }

    public var message: String {
        switch self {
        case .offline:
            #if os(iOS)
            return "Connect to Wi-Fi or cellular data to run a speed test."
            #else
            return "Connect to a network to run a speed test."
            #endif
        case .dataNotAllowed:
            #if os(iOS)
            return "This network won't carry the test. Check that cellular data is enabled for this app and that Low Data Mode is off."
            #else
            return "This network won't carry the test. Check that Low Data Mode is off for this network."
            #endif
        case .unreachable:
            return "You're connected, but speed.cloudflare.com didn't respond. You may be behind a captive portal or on a network that blocks it."
        case .interrupted:
            return "The connection dropped partway through, so there isn't enough data for an accurate result."
        case .rejected(let statusCode) where statusCode == 429:
            return "speed.cloudflare.com is limiting requests from your network (HTTP 429). Wait a few minutes and try again."
        case .rejected(let statusCode):
            return "speed.cloudflare.com answered with HTTP \(statusCode) instead of test data. A network filter or proxy may be blocking it."
        case .unknown(let description):
            return description
        }
    }

    public var systemImage: String {
        switch self {
        case .offline: return "wifi.slash"
        case .dataNotAllowed: return "exclamationmark.shield"
        case .unreachable: return "exclamationmark.triangle"
        case .interrupted: return "bolt.horizontal.circle"
        case .rejected: return "hand.raised"
        case .unknown: return "xmark.circle"
        }
    }
}

/// The five grades speed.cloudflare.com shows for each network experience.
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
    ///   - jitterMs: unloaded (idle) jitter. `nil` (fewer than two idle
    ///     samples) also makes the score unavailable.
    ///   - loadedLatencyIncreaseMs: max(loaded download latency, loaded upload latency) − unloaded latency.
    ///     `nil` when the loaded-latency probes returned nothing, which makes
    ///     the whole score unavailable — see below.
    ///   - packetLoss: fraction 0...1. This engine doesn't measure packet
    ///     loss (it needs a TURN server), so callers pass 0, which is also
    ///     what Cloudflare's JS engine falls back to.
    ///
    /// Returns nil when the loaded-latency increase or jitter wasn't
    /// measured. In these tables lower is better, so substituting 0 would
    /// score a missing measurement as ideal.
    ///
    /// Note: none of Cloudflare's three published experiences (streaming,
    /// gaming, rtc) factor in upload bandwidth at all — only download does,
    /// and only for streaming. That's their real scoring table, not an
    /// omission here.
    public init?(download: Double, latencyMs: Double, jitterMs: Double?, loadedLatencyIncreaseMs: Double?, packetLoss: Double = 0) {
        guard let loadedLatencyIncreaseMs, let jitterMs else { return nil }
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

/// Everything a completed run measured.
public struct TestResult: Sendable, Equatable {
    /// When the run finished.
    public var date: Date
    public var meta: NetworkMeta
    public var idleLatency: LatencySummary
    public var download: ThroughputSummary
    /// `nil` when no probe came back during the phase — distinct from
    /// "measured, and it was 0 ms".
    public var downloadLoadedLatency: LatencySummary?
    public var upload: ThroughputSummary
    public var uploadLoadedLatency: LatencySummary?
    /// `nil` when a metric the scoring tables need wasn't measured. The UI
    /// hides the quality card rather than showing a grade we can't justify.
    public var quality: NetworkQuality?

    /// Every byte the download and upload phases moved, ramp-up included.
    public var bytesTransferred: UInt64 { download.bytes &+ upload.bytes }

    public init(date: Date = .now, meta: NetworkMeta, idleLatency: LatencySummary, download: ThroughputSummary, downloadLoadedLatency: LatencySummary?, upload: ThroughputSummary, uploadLoadedLatency: LatencySummary?) {
        self.date = date
        self.meta = meta
        self.idleLatency = idleLatency
        self.download = download
        self.downloadLoadedLatency = downloadLoadedLatency
        self.upload = upload
        self.uploadLoadedLatency = uploadLoadedLatency

        let loadedMedians = [downloadLoadedLatency?.medianMs, uploadLoadedLatency?.medianMs].compactMap { $0 }
        let loadedLatencyIncrease = loadedMedians.max().map { max(0, $0 - idleLatency.medianMs) }
        self.quality = NetworkQuality(
            download: download.p90Mbps,
            latencyMs: idleLatency.medianMs,
            jitterMs: idleLatency.jitterMs,
            loadedLatencyIncreaseMs: loadedLatencyIncrease
        )
    }
}

/// Tunables for a run. `.default` matches what the apps ship with; every
/// value is clamped by `sanitized()` before use.
public struct SpeedTestConfig: Sendable {
    /// Must be HTTPS; anything else falls back to speed.cloudflare.com.
    public var baseURL: URL
    /// Parallel transfer workers per throughput phase.
    public var concurrency: Int
    /// Phases are fixed-duration, not fixed-size, so a run takes the same
    /// time on a 10 Mbps link as on a 10 Gbps one.
    public var downloadDuration: TimeInterval
    public var uploadDuration: TimeInterval
    /// Size each worker requests per download. Large enough that a worker
    /// spends its time transferring rather than starting requests; a
    /// transfer still running at the deadline is cancelled mid-stream.
    public var downloadBytesPerRequest: Int
    public var uploadBytesPerRequest: Int
    /// Sequential probes in the unloaded (idle) latency batch.
    public var idleLatencyProbeCount: Int
    /// How often throughput is sampled; also the live graph's tick rate.
    public var sampleInterval: TimeInterval

    public static let `default` = SpeedTestConfig(
        baseURL: URL(string: "https://speed.cloudflare.com")!, // static literal, cannot fail
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

    /// Most throughput workers a run will use. Leaves room under the client's
    /// per-host connection limit (`CloudflareClient.maxConnections`) for the
    /// loaded-latency probe and metadata requests, which would otherwise queue
    /// behind transfers and read as extra latency.
    public static let maxConcurrency = 8

    /// Largest upload body per request. Each worker shares one buffer, but it
    /// still lives in memory for the whole phase.
    public static let maxUploadBytesPerRequest = 50_000_000

    /// Largest download size requested per transfer.
    public static let maxDownloadBytesPerRequest = 1_000_000_000

    /// A copy safe to run: values clamped into ranges the engine can handle
    /// (a zero `sampleInterval` would divide by zero; zero workers would
    /// measure nothing), and the base URL forced to HTTPS — measurement
    /// traffic never goes out in clear, and a malformed URL falls back to
    /// the default endpoint rather than crashing.
    public func sanitized() -> SpeedTestConfig {
        var copy = self
        if baseURL.scheme?.lowercased() != "https" || (baseURL.host ?? "").isEmpty {
            copy.baseURL = Self.default.baseURL
        }
        copy.concurrency = min(max(concurrency, 1), Self.maxConcurrency)
        copy.sampleInterval = sampleInterval.isFinite ? min(max(sampleInterval, 0.05), 2) : Self.default.sampleInterval
        copy.downloadDuration = downloadDuration.isFinite ? min(max(downloadDuration, 1), 60) : Self.default.downloadDuration
        copy.uploadDuration = uploadDuration.isFinite ? min(max(uploadDuration, 1), 60) : Self.default.uploadDuration
        copy.downloadBytesPerRequest = min(max(downloadBytesPerRequest, 1), Self.maxDownloadBytesPerRequest)
        copy.uploadBytesPerRequest = min(max(uploadBytesPerRequest, 1), Self.maxUploadBytesPerRequest)
        copy.idleLatencyProbeCount = min(max(idleLatencyProbeCount, 1), 50)
        return copy
    }
}
