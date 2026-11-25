# Edge Speed

[![CI](https://github.com/aashishvanand/speed-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/aashishvanand/speed-ios/actions/workflows/ci.yml)

A native internet speed test for iPhone, iPad, Apple TV and Mac, built on the
public [speed.cloudflare.com](https://speed.cloudflare.com) endpoints. It
measures download, upload, idle and loaded latency, and jitter, then grades the
connection for streaming, gaming and video calls using Cloudflare's published
scoring.

> **Unofficial.** This is an independent project. It is not affiliated with,
> endorsed by, or supported by Cloudflare, Inc. "Cloudflare" is a trademark of
> Cloudflare, Inc.

## Features

- **Fixed-duration phases.** Idle latency, then download and upload with
  latency measured under load. A run takes the same time on any link.
- **Live graph.** Throughput is sampled every 200 ms and drawn as the test runs.
- **Network quality.** Video streaming, online gaming and video chatting are
  graded with the same thresholds speed.cloudflare.com uses.
- **Clear failures.** Offline, data not allowed, captive portal, rate limited
  and dropped connection are each reported as such, never as a 0 Mbps result.
- **Data-aware.** A test starts on its own only on an unmetered connection
  without Low Data Mode, and automatic starts can be turned off entirely
  (Options → Start Tests Automatically). Each result shows how much data the
  run used. A tap always works.
- **Local history.** The last 200 results, stored on the device only.
- **Accessible.** VoiceOver labels and announcements, Dynamic Type up to the
  largest accessibility sizes, and Reduce Motion.

## How it measures

The engine follows the protocol of speed.cloudflare.com and its open-source
engine, [cloudflare/speedtest](https://github.com/cloudflare/speedtest).

| Measurement | Request | Method |
|---|---|---|
| Latency | `GET /__down?bytes=0` | Request start to response start, minus the server time the edge reports in `Server-Timing`. Connection setup isn't counted. |
| Download | `GET /__down?bytes=N` | 6 parallel workers for 8 s. Bytes are counted as they arrive and never buffered. |
| Upload | `POST /__up` | 6 parallel workers for 8 s, counted from send progress. |
| Loaded latency | `GET /__down?bytes=0` | Probed throughout each transfer phase. |
| Metadata | `/meta`, `/cdn-cgi/trace`, `/locations` | Data center, ISP and map location. Fetched alongside the test, never blocking it. |

- **Headline number.** Throughput is sampled every 200 ms. The first 20% of each
  phase (at least 1 s) is dropped as TCP ramp-up, and the 90th percentile of the
  remaining samples is reported. speed.cloudflare.com also reports a 90th
  percentile, but over per-request measurements rather than time slices, so
  the two can differ.
- **Jitter.** The mean absolute difference between consecutive idle-latency
  samples.
- **Quality grades.** A direct port of the AIM scoring tables in
  `cloudflare/speedtest`. When a metric the tables need wasn't measured, no
  grade is shown rather than a guessed one.
- **Error pages are never counted.** A response's status is checked when its
  headers arrive. A non-2xx body is cancelled before any of it counts as
  throughput.

### Limitations

- Packet loss isn't measured. Cloudflare measures it over WebRTC through a TURN
  server, which this app doesn't use. The scoring treats it as 0, which is also
  what Cloudflare's engine does when it's unavailable.
- One server per run: the data center Cloudflare's anycast routing picks. There's
  no IPv4/IPv6 comparison.

## Architecture

```
App/
  Shared/            SwiftUI views used by every platform
  CFSpeed/           iOS and iPadOS app
  CFSpeed-tvOS/      tvOS app
  CFSpeed-macOS/     macOS app (sandboxed, outgoing network only)
Packages/CFSpeedKit/ The engine, as a Swift package with no dependencies
project.yml          XcodeGen spec; the .xcodeproj is generated from it (committed for Xcode Cloud; rerun xcodegen after editing)
```

Key types in `CFSpeedKit`:

- **`SpeedTestRunner`** runs the phases in order and publishes live state to the
  UI. It is `@MainActor` and `@Observable`. Each run has an ID, so a cancelled
  or superseded run can never write over a newer one.
- **`CloudflareClient`** wraps the endpoints. It uses an ephemeral session with
  no cache, cookies or credentials, so no request is answered from local state.
- **`TransferDelegate` and `ByteCounter`** count bytes straight from URLSession
  delegate callbacks into a lock-protected counter. An actor would need a task
  per callback, thousands per second, all competing with the sampling clock.
- **`HistoryStore`** keeps results in SwiftData, local only, with CloudKit
  explicitly disabled, pruned to the newest 200.

The package builds in the Swift 6 language mode with complete data-race
checking, as do all three apps.

## Requirements

- Xcode 27 or later
- iOS, iPadOS, tvOS and macOS 26 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)

## Getting started

```bash
brew install xcodegen
xcodegen generate
open CFSpeed.xcodeproj
```

To run on a device, set your own team and bundle IDs in `project.yml`.

## Testing

The engine tests run against an in-process fake of speed.cloudflare.com (a
`URLProtocol` stub), so they're fast and send no network traffic:

```bash
cd Packages/CFSpeedKit
swift test
```

One integration test runs a real (shortened) test against speed.cloudflare.com.
It's skipped unless you opt in:

```bash
CF_SPEEDTEST_LIVE=1 swift test --filter SpeedTestRunnerIntegrationTests
```

UI tests (from the `CFSpeedUITests` / `CFSpeedTVUITests` / `CFSpeedMacUITests`
targets) cover the accessibility tree, landscape, Dynamic Type,
swipe-to-delete, and — with the simulated remote — tvOS focus scrolling and the
long-press delete menu, plus the same accessibility tree and History sheet on
the Mac. They run in the Debug demo scenes, so they too send no network
traffic. Run them locally against a booted simulator (and the Mac):

```bash
xcodebuild test -project CFSpeed.xcodeproj -scheme CFSpeed \
  -destination 'platform=iOS Simulator,name=iPhone 17e'
xcodebuild test -project CFSpeed.xcodeproj -scheme CFSpeed-tvOS \
  -destination 'platform=tvOS Simulator,name=Apple TV 4K (4th generation)'
xcodebuild test -project CFSpeed.xcodeproj -scheme CFSpeed-macOS \
  -destination 'platform=macOS'
```

Xcode Cloud runs the engine tests before every release archive
(`ci_scripts/ci_pre_xcodebuild.sh`), and a failure stops the build. The GitHub
Actions workflow, which runs the engine tests on macOS, iOS and tvOS and builds
all three apps, is manual only: start it from the Actions tab.

## Localization

The UI is English-only for now, with `App/Shared/Localizable.xcstrings` (shared
by all three app targets) as the hook for translations. It already holds every
static UI string. The status-line strings and the engine's failure titles are
composed at runtime and stay English until a second language is added. Refresh
the catalog after adding or changing UI strings:

```bash
xcodebuild -exportLocalizations -project CFSpeed.xcodeproj \
  -localizationPath <somewhere-temporary> -exportLanguage en
```

## Branches and releases

- `dev`: day-to-day work. Pushes don't trigger any CI.
- `testflight`: release branch. Xcode Cloud archives the iOS, tvOS and macOS
  apps from each push and uploads them to TestFlight. To ship a build, open
  a pull request from `dev` into `testflight`
  (`gh pr create --base testflight --head dev`) and merge it. Xcode Cloud runs
  the engine tests before archiving; run the GitHub workflow by hand first if
  you want the full cross-platform check.
  A direct `git push origin dev:testflight` is rejected after the first
  merge, because `testflight` then has merge commits that `dev` lacks.
- `website`: the privacy, terms and support pages, deployed as a Cloudflare
  Worker.

Xcode Cloud doesn't run XcodeGen itself, so `ci_scripts/ci_post_clone.sh`
generates `CFSpeed.xcodeproj` before it builds, with a pinned XcodeGen release
whose SHA-256 is checked before it runs. The GitHub workflow uses the same script.

The version and build number for all three apps are `MARKETING_VERSION` and
`CURRENT_PROJECT_VERSION` in `project.yml`. Raise the build number for each
TestFlight upload and add an entry to [CHANGELOG.md](CHANGELOG.md).

## Privacy

The app has no analytics, no tracking and no account. Measurement traffic goes
only to speed.cloudflare.com; the server map is drawn by Apple Maps. Test
history stays on the device. See the [privacy policy](https://speed-ios-website.aashishvanand.workers.dev/privacy)
and [terms of use](https://speed-ios-website.aashishvanand.workers.dev/terms). The site's
source is on the [`website`](../../tree/website) branch, deployed as a Cloudflare Worker.

## Publishing

`AppStore/README.md` (local only, gitignored) has the store listing,
privacy-label and review answers.
`scripts/generate-icons.swift` draws every app icon, and
`scripts/take-screenshots.sh` captures store screenshots from a Debug-only
demo mode (`-demo result|download|details|history`) with sample data.

## Acknowledgments

- [cloudflare/speedtest](https://github.com/cloudflare/speedtest), for the
  measurement protocol and quality scoring.
- [cloudflare-speed-cli](https://github.com/kavehtehrani/cloudflare-speed-cli),
  which inspired the engine's structure.

## License

[MIT](LICENSE)
