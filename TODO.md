# TODO

Triaged from an external review (2026-11-07), with each claim checked against the code.
Priority shows how much the issue affects users, not the order it was listed in the review.

**Status: all items implemented (2026-11-07).** Verified with `swift test` (15 tests), a live run
(`CF_SPEEDTEST_LIVE=1`: 3 s + 3 s phases, finished in 7.4 s), and warning-free Swift 6 builds of all three apps.
Implementation notes that differ from the original suggestions are marked *Done as:*.

## P0: Wrong results or very long hangs

- [x] **Upload phase overruns its duration and ignores cancellation.** `Throughput.swift:81-121`
  Upload workers check `stop` only between requests, and the group waits for them all. At 1 Mbps a 5 MB body takes about 40 s, so an "8 s" phase can run for close to a minute.
  Cancellation is also broken: `while await !stop.isStopped` never checks `Task.isCancelled`. A cancelled `upload(for:)` throws, the worker records an error, sleeps and loops again. Meanwhile the sampler's `try? Task.sleep` keeps the clock running for the whole duration.
  Fix: put the sampling loop in the group body, as the download phase does, then call `group.cancelAll()`. Workers should loop on `!Task.isCancelled`.

- [x] **A blackholed or captive-portal network takes about 80 s to report failure.** `SpeedTestRunner.swift:51-57`, `Latency.swift:24-39`
  The review estimated about 50 s, but it is worse. First, `fetchTrace()` and `fetchMetaInfo()` run with the session's 30 s timeout *before* any probe. Then 10 probes × 5 s timeout run, and timeouts are non-terminal.
  Fix: stop after 3 consecutive failures, or set a total budget of about 8 s, and report the last error. Also see the next item.

- [x] **Metadata blocks the start of the test.** `SpeedTestRunner.swift:51-57`
  Start the latency probes right away and merge metadata when it arrives (it is decoration only). Cache the decoded `/locations` list for the app session, and skip `/locations` on tvOS, which has no map.
  Caveat: metadata requests that overlap the idle-latency probes add a little noise. That's acceptable because the requests are tiny, but they should not be awaited.

- [x] **Backgrounding during a run can save bad numbers to history.** `SpeedTestView.swift`
  Suspended transfers still count against wall-clock time. A run that resumes and "finishes" can produce a low download/upload number that gets saved.
  Fix: watch `scenePhase` and cancel/reset the run when the app goes to the background (iOS/tvOS).

## P1: Measurement accuracy and efficiency

- [x] **Replace the `ByteCounter` actor hop on the hot path.** `ByteCounter.swift:39,79`
  Every `didReceive data` and `didSendBodyData` spawns `Task { await counter.add }`, which means thousands of tasks per second. These compete with the sampler, and snapshots lag the wire.
  *Done as:* `OSAllocatedUnfairLock` (kept iOS 17 package platforms). The delegates are now really `Sendable`, without `@unchecked`.
  Fix: use a synchronous counter based on `OSAllocatedUnfairLock`. `Synchronization.Atomic` needs iOS 18, and `Package.swift` still declares iOS 17 / macOS 14, so either use the lock or raise the package platforms to 26 to match the apps.

- [x] **Sampling clock drift.** `Throughput.swift:54-63, 109-118`, `Latency.swift:54-61`
  `elapsed += interval` assumes `Task.sleep` is exact, and Mbps is computed from the nominal interval.
  Fix: use `ContinuousClock`, record the actual instant of each snapshot, and compute Mbps from the measured Δt. Replace the `Date()` deadline in loaded latency the same way.

- [x] **Disable URL caching on the measurement session.** `CloudflareClient.swift:15-27`
  Every probe hits the same URL (`__down?bytes=0&measId=<same>`). An `.ephemeral` session still has an in-memory `URLCache`, so this setting protects correctness, not just privacy.
  Set `urlCache = nil` and `requestCachePolicy = .reloadIgnoringLocalCacheData`. Also set `httpShouldSetCookies = false`, `httpCookieAcceptPolicy = .never` and `urlCredentialStorage = nil`. TLS 1.2 is already the OS minimum, so there's no need to set it.

- [x] **The `URLSession` leaks on every run.** `CloudflareClient.swift:26`
  A new session is created per run and never invalidated. Call `finishTasksAndInvalidate()` (or `invalidateAndCancel()` on cancel) when the run ends.

## P2: Data use, privacy and App Store

- [x] **Don't auto-run on expensive or constrained paths.** `SpeedTestView.swift:70-86`
  Auto-start on launch, and the auto-retry when connectivity returns, can use hundreds of MB to more than 1 GB on a fast link. Gate both on `!path.isExpensive && !path.isConstrained` (expose this from `ConnectivityMonitor`). A manual tap stays unrestricted.

- [x] **Store a stable code for `ConnectionType`.** `TestHistory.swift:5-11`
  The raw values are display strings ("Wi-Fi"). Change them to stable codes and add a separate `displayName` before the first release, while there is no history to migrate yet.

- [x] **Explicitly disable CloudKit for SwiftData.** `CFSpeedApp.swift`, `CFSpeedTVApp.swift`, `CFSpeedMacApp.swift`
  `ModelConfiguration(cloudKitDatabase: .none)`. SwiftData turns on sync automatically if an iCloud entitlement is ever added.

- [x] **Add App Store metadata.**
  - `PrivacyInfo.xcprivacy` per target (`NSPrivacyTracking = false`, no collected data types).
  - `ITSAppUsesNonExemptEncryption = false` in all three Info.plists (via `project.yml`).
  - `LSApplicationCategoryType = public.app-category.utilities` for macOS.

- [x] **History retention.** `HistoryView.swift`, `SpeedTestView.swift:88-98`
  Keep the newest N (for example 200) on insert. Use `modelContext.delete(model: TestHistoryEntry.self)` for "Clear All".

- [x] **Log SwiftData save failures** with `Logger` instead of `try?`. `SpeedTestView.swift:97`, `HistoryView.swift:100,106,112`

- [x] **Fix the previews**, which crash without a container. Add `.modelContainer(for: TestHistoryEntry.self, inMemory: true)`. `SpeedTestView.swift:619`, `HistoryView.swift:116`

## P3: Cleanup and hardening

- [x] **Reduce SwiftUI invalidation.** *Done as:* `@Observable` runner/monitor plus the `HeroCard` and `SecondaryStatsRow` child views. `SpeedTestRunner`/`ConnectivityMonitor` → `@Observable`, and split the hero/graph/chips into child views. Also switch `.animation(.snappy)` on the 5 Hz hero number to a short `.linear`, or remove it.
  Note: the review overstated this. The sample arrays are bounded at about 40 entries (8 s / 0.2 s), so they don't grow without limit. The real cost is re-rendering the whole ~600-line body 5×/s.
- [x] **Deliver ticks to the main actor in order.** Today each `Task { @MainActor in … }` per tick can reorder samples. Use an `AsyncStream` consumed on the main actor instead.
- [x] **Remove the force-unwraps in the URL builders** (`CloudflareClient.swift:30,35,39,41`) and require `https` in the client init. The base URL isn't user input today, so this is defensive.
- [x] **Clamp `SpeedTestConfig`** values: `concurrency ≥ 1` and `sampleInterval > 0`. A zero `sampleInterval` divides by zero.
- [x] **Turn on strict concurrency** *Done as:* Swift 6 language mode for the package and all three app targets. (Swift 6 mode or `-strict-concurrency=complete`) and audit the `@unchecked Sendable` delegates and client.
- [x] **Add CI**: `swift test` plus `xcodebuild build` for all three schemes.

## Considered, not doing

- **Upload from a temp file instead of `Data`.** `Data(count:)` is one copy-on-write 5 MB buffer shared by all workers, so there is no per-request copy worth removing.
- **Setting the minimum TLS version explicitly.** The OS default is already TLS 1.2+.
- **Moving the team ID and bundle IDs out of `project.yml`.** They aren't secrets, so this is optional cosmetics.
