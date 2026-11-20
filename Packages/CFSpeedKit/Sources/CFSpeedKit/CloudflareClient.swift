import Foundation
import os

/// Thin wrapper around Cloudflare's public speed-test endpoints
/// (speed.cloudflare.com/__down, /__up, /meta, /cdn-cgi/trace).
/// See https://speed.cloudflare.com/about/ for protocol details.
final class CloudflareClient: Sendable {
    let baseURL: URL
    let measId: String
    let session: URLSession

    /// Wall-clock limit on each best-effort metadata call. These are
    /// decoration, so they must never be the thing a user waits on.
    static let metadataTimeout: TimeInterval = 8

    /// Largest metadata body we'll read. /locations, the biggest, is tens of
    /// KB; anything far past that is not the response we asked for.
    static let maxMetadataBytes = 512 * 1024

    /// Per-host connection limit: one per throughput worker, plus room for
    /// the loaded-latency probe and the three metadata calls so they never
    /// queue behind transfers.
    static func maxConnections(forConcurrency concurrency: Int) -> Int {
        concurrency + 4
    }

    /// - Parameter protocolClasses: test hook — routes the session through
    ///   stub `URLProtocol`s instead of the network.
    init(baseURL: URL, measId: String = UUID().uuidString, concurrency: Int = SpeedTestConfig.default.concurrency, protocolClasses: [AnyClass]? = nil) {
        self.baseURL = baseURL
        self.measId = measId

        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["Referer": "https://speed.cloudflare.com/"]
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = Self.maxConnections(forConcurrency: concurrency)
        // Deliberately opted out of the usual advice to let the session wait
        // for connectivity. A speed test measures wall-clock transfer over a
        // fixed duration, so a session that silently stalls and resumes later
        // would either fold the wait into the measurement or start measuring
        // at an arbitrary moment. Failing fast lets the runner report *why*
        // instead — see `TestFailure`.
        config.waitsForConnectivity = false
        // Every latency probe hits the same URL, and `.ephemeral` still keeps
        // an in-memory URLCache — a cached reply would read as a ~0 ms RTT.
        // No cache, no cookies, no credentials: the measurement session
        // carries no state between requests.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        config.urlCredentialStorage = nil
        if let protocolClasses {
            config.protocolClasses = protocolClasses
        }
        self.session = URLSession(configuration: config)
    }

    /// URLSession retains itself until invalidated; a client lives for exactly
    /// one run, so the runner calls this when the run ends.
    func invalidate() {
        session.invalidateAndCancel()
    }

    func downURL(bytes: Int) -> URL {
        baseURL.appending(path: "__down").appending(queryItems: [
            URLQueryItem(name: "bytes", value: String(bytes)),
            URLQueryItem(name: "measId", value: measId),
        ])
    }

    func upURL() -> URL {
        baseURL.appending(path: "__up").appending(queryItems: [
            URLQueryItem(name: "measId", value: measId),
        ])
    }

    /// Fetches a metadata body, or nil on any failure: an error status, a body
    /// over `maxMetadataBytes`, or `metadataTimeout` passing — a real deadline,
    /// not URLRequest's idle timeout, which a trickling response can keep
    /// resetting indefinitely.
    func fetchMetadata(_ path: String) async -> Data? {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = Self.metadataTimeout
        let deadline = ContinuousClock.now + .seconds(Self.metadataTimeout)
        let limit = Self.maxMetadataBytes
        let result = try? await withDeadline(deadline) { [session, request] () async throws -> Data? in
            // A data task with a capping delegate, not `bytes(for:)`: AsyncBytes
            // resumes once per byte, which for tens of KB of /locations means
            // tens of thousands of hops on the cooperative pool while the idle
            // latency probes are being timed. See `TransferDelegate`.
            let task = session.dataTask(with: request)
            let delegate = CappedBodyDelegate(limit: limit)
            task.delegate = delegate
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    delegate.attach(continuation)
                    task.resume()
                }
            } onCancel: {
                task.cancel()
            }
        }
        return result ?? nil
    }

    /// Single round-trip latency probe: GET /__down?bytes=0.
    ///
    /// Measured the way speed.cloudflare.com measures it: request start to
    /// response start, minus the server processing time the edge reports in
    /// Server-Timing. Using the task's own metrics excludes DNS, TCP and TLS
    /// setup, so the first probe on a new connection isn't inflated by two or
    /// three extra round trips. Falls back to wall-clock time if the system
    /// reports no metrics.
    ///
    /// Throws rather than returning nil: this is the first request a run
    /// makes, so its `URLError` is what tells the runner *why* a test can't
    /// proceed (offline vs. blocked vs. timing out).
    func probeLatencyMs(timeout: TimeInterval = 5) async throws -> Double {
        var request = URLRequest(url: downURL(bytes: 0))
        request.timeoutInterval = timeout
        let metrics = ProbeMetrics()
        let start = DispatchTime.now()
        let (_, response) = try await session.data(for: request, delegate: metrics)
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        // A fast 403 or 429 is not a round trip to a working edge.
        guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        guard http.isSuccess else { throw HTTPStatusError(statusCode: http.statusCode) }
        let totalMs = metrics.requestToResponse.map { $0 * 1000 } ?? Double(elapsedNs) / 1_000_000.0
        // The edge spends tens of milliseconds generating each response, often
        // several times the network round trip itself. It reports that time in
        // Server-Timing, and speed.cloudflare.com subtracts it; so do we.
        let serverMs = Self.serverProcessingMs(serverTiming: http.value(forHTTPHeaderField: "Server-Timing"))
        return max(totalMs - serverMs, 0)
    }

    /// Total server-side processing time, in milliseconds, from a
    /// Server-Timing header such as `cfSpeedEdge;dur=3, cfSpeedWorker;dur=15`.
    ///
    /// Sums the `dur` of Cloudflare's speed-test entries (`cfSpeed*`, and the
    /// older `cfRequestDuration`). Other entries are ignored: `cfL4`, for
    /// example, describes the TCP connection, not time spent on the request.
    /// Returns 0 when the header is missing or has no usable entry.
    static func serverProcessingMs(serverTiming: String?) -> Double {
        guard let serverTiming else { return 0 }
        var total = 0.0
        for entry in serverTiming.split(separator: ",") {
            let params = entry.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let name = params.first,
                  name.hasPrefix("cfSpeed") || name == "cfRequestDuration" else { continue }
            for param in params.dropFirst() where param.hasPrefix("dur=") {
                if let ms = Double(param.dropFirst(4)), ms.isFinite, ms >= 0 {
                    total += ms
                }
            }
        }
        return total
    }

    func meta(from response: URLResponse) -> NetworkMeta {
        guard let http = response as? HTTPURLResponse else { return NetworkMeta() }
        let headers = http.allHeaderFields
        func header(_ name: String) -> String? {
            (headers[name] as? String) ?? (headers[name.lowercased()] as? String)
        }

        var meta = NetworkMeta(
            clientIP: header("cf-meta-ip"),
            colo: header("cf-meta-colo"),
            city: header("cf-meta-city"),
            country: header("cf-meta-country"),
            asn: header("cf-meta-asn")
        )

        if meta.clientIP == nil {
            meta.clientIP = header("cf-connecting-ip") ?? header("CF-Connecting-IP")
        }
        if meta.colo == nil, let ray = header("cf-ray") ?? header("CF-RAY") {
            let parts = ray.split(separator: "-")
            if parts.count > 1 {
                meta.colo = String(parts[1])
            }
        }
        return meta
    }

    /// GET /cdn-cgi/trace — plain key=value text, fallback source for client IP/colo.
    func fetchTrace() async -> NetworkMeta {
        var meta = NetworkMeta()
        guard let data = await fetchMetadata("cdn-cgi/trace"),
              let text = String(data: data, encoding: .utf8) else {
            return meta
        }
        for line in text.split(separator: "\n") {
            let kv = line.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            switch kv[0] {
            case "ip": meta.clientIP = String(kv[1])
            case "colo": meta.colo = String(kv[1])
            case "loc": meta.country = String(kv[1])
            default: break
            }
        }
        return meta
    }

    /// GET /locations — static list of every Cloudflare edge colo with its
    /// IATA code and coordinates, used to plot the test's colo on a map.
    func fetchLocations() async -> [ColoLocation] {
        guard let data = await fetchMetadata("locations"),
              let locations = try? JSONDecoder().decode([ColoLocation].self, from: data) else {
            return []
        }
        return locations
    }

    /// GET /meta — richest single source of truth: the client's ISP name
    /// (asOrganization, not available via headers or /cdn-cgi/trace) plus
    /// the colo's own city/coordinates.
    func fetchMetaInfo() async -> NetworkMeta {
        guard let data = await fetchMetadata("meta"),
              let response = try? JSONDecoder().decode(MetaResponse.self, from: data) else {
            return NetworkMeta()
        }
        return NetworkMeta(
            colo: response.colo?.iata,
            city: response.colo?.city,
            country: response.country,
            asn: response.asn.map(String.init),
            ispName: response.asOrganization,
            latitude: response.colo?.lat,
            longitude: response.colo?.lon
        )
    }
}

/// Collects one small response body in memory, up to `limit` bytes. Resumes
/// with nil, and stops reading, on a non-2xx status or a body over the limit.
private final class CappedBodyDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<Data?, Error>?
        var data = Data()
        var refused = false
    }

    private let limit: Int
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    init(limit: Int) {
        self.limit = limit
    }

    /// Called before `resume()`, so it always runs ahead of any callback.
    func attach(_ continuation: CheckedContinuation<Data?, Error>) {
        state.withLockUnchecked { $0.continuation = continuation }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let ok = (response as? HTTPURLResponse)?.isSuccess == true && response.expectedContentLength <= Int64(limit)
        if !ok { state.withLockUnchecked { $0.refused = true } }
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let overLimit = state.withLockUnchecked { state -> Bool in
            state.data.append(data)
            if state.data.count > limit {
                state.refused = true
                state.data = Data()
                return true
            }
            return false
        }
        if overLimit { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, data, refused) = state.withLockUnchecked { state in
            defer { state.continuation = nil }
            return (state.continuation, state.data, state.refused)
        }
        // Our own cancel of a refused response surfaces as an error; that's
        // a plain "no metadata", not a failure.
        if refused {
            continuation?.resume(returning: nil)
        } else if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: data)
        }
    }
}

/// Captures one probe's request-start to response-start interval.
private final class ProbeMetrics: NSObject, URLSessionTaskDelegate, Sendable {
    private let interval = OSAllocatedUnfairLock<TimeInterval?>(initialState: nil)

    /// Nil when the system reported no usable timestamps.
    var requestToResponse: TimeInterval? { interval.withLock { $0 } }

    func urlSession(_ session: URLSession, task: URLSessionTask, didFinishCollecting metrics: URLSessionTaskMetrics) {
        // The last transaction is the one that produced the response (earlier
        // ones would be redirects).
        guard let transaction = metrics.transactionMetrics.last,
              let requestStart = transaction.requestStartDate,
              let responseStart = transaction.responseStartDate,
              responseStart >= requestStart else { return }
        interval.withLock { $0 = responseStart.timeIntervalSince(requestStart) }
    }
}

struct ColoLocation: Decodable, Sendable {
    let iata: String
    let lat: Double
    let lon: Double
    let cca2: String
    let city: String
}

private struct MetaResponse: Decodable {
    let asn: Int?
    let asOrganization: String?
    let country: String?
    let colo: MetaColo?
}

private struct MetaColo: Decodable {
    let iata: String?
    let lat: Double?
    let lon: Double?
    let city: String?
}
