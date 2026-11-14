import Foundation
import os
@testable import CFSpeedKit

/// How the stub answers one request.
enum StubReply: Sendable {
    case respond(status: Int, body: Data = Data(), delay: TimeInterval = 0)
    /// Never answers, until the request is cancelled.
    case stall
}

/// A fake speed.cloudflare.com, one per test, addressed by a unique host so
/// tests can run in parallel without sharing state.
struct StubServer: Sendable {
    var probe: StubReply = .respond(status: 200, delay: 0.005)
    var download: StubReply = .respond(status: 200, body: Data(count: 64 * 1024), delay: 0.02)
    var upload: StubReply = .respond(status: 200, delay: 0.02)
    var meta: StubReply = .respond(status: 200, body: Data(#"{"asn":13335,"asOrganization":"Stub ISP","country":"US","colo":{"iata":"SFO","lat":37.6,"lon":-122.4,"city":"San Francisco"}}"#.utf8))
    var trace: StubReply = .respond(status: 200, body: Data("ip=192.0.2.1\ncolo=SFO\nloc=US\n".utf8))
    var locations: StubReply = .respond(status: 404)

    func reply(to request: URLRequest) -> StubReply {
        guard let url = request.url else { return .respond(status: 400) }
        switch url.path {
        case "/__down":
            let isProbe = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first(where: { $0.name == "bytes" })?.value == "0"
            return isProbe ? probe : download
        case "/__up": return upload
        case "/meta": return meta
        case "/cdn-cgi/trace": return trace
        case "/locations": return locations
        default: return .respond(status: 404)
        }
    }

    /// Registers this server under a fresh host and returns its base URL.
    func install() -> URL {
        let host = "\(UUID().uuidString.lowercased()).stub.test"
        StubProtocol.servers.withLock { $0[host] = self }
        return URL(string: "https://\(host)")!
    }

    static func uninstall(_ baseURL: URL) {
        guard let host = baseURL.host else { return }
        StubProtocol.servers.withLock { _ = $0.removeValue(forKey: host) }
    }
}

final class StubProtocol: URLProtocol, @unchecked Sendable {
    static let servers = OSAllocatedUnfairLock<[String: StubServer]>(initialState: [:])

    private let stopped = OSAllocatedUnfairLock(initialState: false)

    override class func canInit(with request: URLRequest) -> Bool {
        guard let host = request.url?.host else { return false }
        return servers.withLock { $0[host] != nil }
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let host = url.host,
              let server = Self.servers.withLock({ $0[host] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.cannotConnectToHost))
            return
        }
        switch server.reply(to: request) {
        case .stall:
            return
        case let .respond(status, body, delay):
            let deliver: @Sendable () -> Void = { [self] in
                guard !stopped.withLock({ $0 }) else { return }
                let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [
                    "Content-Length": String(body.count),
                    "cf-meta-colo": "SFO",
                ])!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                if !body.isEmpty { client?.urlProtocol(self, didLoad: body) }
                client?.urlProtocolDidFinishLoading(self)
            }
            if delay > 0 {
                DispatchQueue.global().asyncAfter(deadline: .now() + delay, execute: deliver)
            } else {
                deliver()
            }
        }
    }

    override func stopLoading() {
        stopped.withLock { $0 = true }
    }
}

extension SpeedTestConfig {
    /// Short phases and small bodies, pointed at a stub server.
    static func stub(_ baseURL: URL) -> SpeedTestConfig {
        SpeedTestConfig(
            baseURL: baseURL,
            concurrency: 2,
            downloadDuration: 1,
            uploadDuration: 1,
            downloadBytesPerRequest: 64 * 1024,
            uploadBytesPerRequest: 64 * 1024,
            idleLatencyProbeCount: 3,
            sampleInterval: 0.1
        )
    }
}

extension SpeedTestRunner.Timing {
    static let stub = SpeedTestRunner.Timing(idleLatencyBudget: .seconds(2), metadataGrace: .milliseconds(300))
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitUntil(timeout: TimeInterval = 10, _ condition: () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(timeout)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}
