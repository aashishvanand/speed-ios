import Foundation

/// Thin wrapper around Cloudflare's public speed-test endpoints
/// (speed.cloudflare.com/__down, /__up, /meta, /cdn-cgi/trace).
/// See https://speed.cloudflare.com/about/ for protocol details.
final class CloudflareClient: Sendable {
    let baseURL: URL
    let measId: String
    let session: URLSession

    /// Timeout for the best-effort metadata calls. These are decoration, so
    /// they must never be the thing a user waits on.
    static let metadataTimeout: TimeInterval = 8

    init(baseURL: URL, measId: String = UUID().uuidString) {
        self.baseURL = baseURL
        self.measId = measId

        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["Referer": "https://speed.cloudflare.com/"]
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 12
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

    private func metadataRequest(_ path: String) -> URLRequest {
        var request = URLRequest(url: baseURL.appending(path: path))
        request.timeoutInterval = Self.metadataTimeout
        return request
    }

    /// Single round-trip latency probe: GET /__down?bytes=0. TTFB is the RTT
    /// to the edge.
    ///
    /// Throws rather than returning nil: this is the first request a run
    /// makes, so its `URLError` is what tells us *why* a test can't proceed
    /// (offline vs. blocked vs. timing out). Swallowing it here is what left
    /// the app unable to distinguish those cases.
    func probeLatencyMs(timeout: TimeInterval = 5) async throws -> Double {
        let url = downURL(bytes: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        let start = DispatchTime.now()
        _ = try await session.data(for: request)
        let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(elapsedNs) / 1_000_000.0
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
        guard let (data, _) = try? await session.data(for: metadataRequest("cdn-cgi/trace")),
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
        guard let (data, _) = try? await session.data(for: metadataRequest("locations")),
              let locations = try? JSONDecoder().decode([ColoLocation].self, from: data) else {
            return []
        }
        return locations
    }

    /// GET /meta — richest single source of truth: the client's ISP name
    /// (asOrganization, not available via headers or /cdn-cgi/trace) plus
    /// the colo's own city/coordinates.
    func fetchMetaInfo() async -> NetworkMeta {
        guard let (data, _) = try? await session.data(for: metadataRequest("meta")),
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
