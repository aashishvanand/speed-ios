# cf-speedtest-ios

A Cloudflare-powered internet speed test for iOS, iPadOS, tvOS, and macOS, modeled on
[cloudflare-speed-cli](https://github.com/kavehtehrani/cloudflare-speed-cli).
Uses the public `speed.cloudflare.com` endpoints — no API key required.

## Structure

- `Packages/CFSpeedKit` — Swift Package with the test engine: `CloudflareClient`
  (talks to `/__down`, `/__up`, `/cdn-cgi/trace`), throughput/latency workers,
  and `SpeedTestRunner` (an `@Observable` model orchestrating a full run).
- `App/Shared` — SwiftUI views shared by all app targets.
- `App/CFSpeed` — iOS/iPadOS app target (universal).
- `App/CFSpeed-tvOS` — tvOS app target.
- `App/CFSpeed-macOS` — macOS app target (sandboxed, `network.client` entitlement).
- `project.yml` — [XcodeGen](https://github.com/yonaskolb/XcodeGen) spec. The
  `.xcodeproj` is generated, not committed.

## Setup

```bash
brew install xcodegen
xcodegen generate
open CFSpeed.xcodeproj
```

## Testing

```bash
cd Packages/CFSpeedKit
swift test                          # unit tests
CF_SPEEDTEST_LIVE=1 swift test --filter SpeedTestRunnerIntegrationTests  # hits real Cloudflare endpoints
```

## How the test works

Mirrors cloudflare-speed-cli's protocol against `speed.cloudflare.com`:

- `GET /__down?bytes=0` — latency probe (TTFB = RTT)
- `GET /__down?bytes=N` — download, N concurrent workers for a fixed duration
- `POST /__up` — upload, streamed body, N concurrent workers
- `GET /cdn-cgi/trace` — client IP / colo / location metadata
- Response headers `cf-meta-*` (or `CF-RAY` colo fallback) carry per-request
  edge metadata

Throughput is sampled every 200ms; the first ~20% of each phase (min 1s) is
discarded as TCP ramp-up before computing mean/median/p25/p75/p90 Mbps,
matching the CLI's steady-state approach.

## Status

Single-server test against Cloudflare's default edge, no IPv4/IPv6
comparison, no traceroute (all present in the CLI). Android
(phone + tablet + Android TV) will live in a separate `cf-speedtest-android`
repo — no shared code between Swift and Kotlin, so no benefit to a monorepo.
