import Foundation

/// Thin wrapper around Cloudflare's public speed-test endpoints
/// (speed.cloudflare.com/__down, /__up, /meta, /cdn-cgi/trace).
/// See https://speed.cloudflare.com/about/ for protocol details.
final class CloudflareClient: @unchecked Sendable {
    let baseURL: URL
    let measId: String
    let session: URLSession

    init(baseURL: URL, measId: String = UUID().uuidString) {
        self.baseURL = baseURL
        self.measId = measId

        let config = URLSessionConfiguration.ephemeral
        config.httpAdditionalHeaders = ["Referer": "https://speed.cloudflare.com/"]
        config.timeoutIntervalForRequest = 30
        config.httpMaximumConnectionsPerHost = 12
        config.waitsForConnectivity = false
        self.session = URLSession(configuration: config)
    }

    func downURL(bytes: Int) -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent("__down"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [
            URLQueryItem(name: "bytes", value: String(bytes)),
            URLQueryItem(name: "measId", value: measId),
        ]
        return comps.url!
    }

    func upURL() -> URL {
        var comps = URLComponents(url: baseURL.appendingPathComponent("__up"), resolvingAgainstBaseURL: false)!
        comps.queryItems = [URLQueryItem(name: "measId", value: measId)]
        return comps.url!
    }

    /// Single round-trip latency probe: GET /__down?bytes=0. TTFB is the RTT to the edge.
    func probeLatencyMs() async -> Double? {
        let url = downURL(bytes: 0)
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        let start = DispatchTime.now()
        do {
            let (_, response) = try await session.data(for: request)
            let elapsedNs = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
            _ = response
            return Double(elapsedNs) / 1_000_000.0
        } catch {
            return nil
        }
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
        let url = baseURL.appendingPathComponent("cdn-cgi/trace")
        var meta = NetworkMeta()
        guard let (data, _) = try? await session.data(from: url),
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
        let url = baseURL.appendingPathComponent("locations")
        guard let (data, _) = try? await session.data(from: url),
              let locations = try? JSONDecoder().decode([ColoLocation].self, from: data) else {
            return []
        }
        return locations
    }

    /// GET /meta — richest single source of truth: the client's ISP name
    /// (asOrganization, not available via headers or /cdn-cgi/trace) plus
    /// the colo's own city/coordinates.
    func fetchMetaInfo() async -> NetworkMeta {
        let url = baseURL.appendingPathComponent("meta")
        guard let (data, _) = try? await session.data(from: url),
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
