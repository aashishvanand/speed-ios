import SwiftUI
import SwiftData
#if !os(tvOS)
import MapKit
#endif
import CFSpeedKit

struct SpeedTestView: View {
    @State private var runner = SpeedTestRunner()
    @State private var connectivity = ConnectivityMonitor()
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var colorSchemeContrast
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showHistory = false
    /// Whether a test starts by itself: on launch, on return from the
    /// background, and when the network comes back after a dropped run. A
    /// full test can move a gigabyte or more each way on a fast link, so
    /// people on capped plans the OS can't see (home, satellite, a phone
    /// hotspot that isn't flagged as one) can turn that off.
    @AppStorage("startsAutomatically") private var startsAutomatically = true
    /// A full test on a link the OS flags as costing money or being kept
    /// down (cellular, a hotspot, Low Data Mode) moves as much data as the
    /// link can carry. Auto-start already refuses those links; this is the
    /// same caution for the deliberate tap, and anyone on a plan where the
    /// data doesn't matter can turn it off.
    @AppStorage("warnsBeforeMeteredTest") private var warnsBeforeMeteredTest = true
    /// A manual tap parked on the metered-link confirmation.
    @State private var confirmingMeteredStart = false
    /// Shown only on request: a TV in a shared room and screen shares
    /// shouldn't put the address on display.
    @State private var revealsIP = false
    /// The launch-time automatic run is attempted once per launch, as soon as
    /// the network path is known.
    @State private var didConsiderAutoStart = false
    /// A run cut short by backgrounding, to pick back up on return.
    @State private var resumeWhenActive = false
    /// Width of the scrollable area, which decides between one and two columns.
    @State private var availableWidth: CGFloat = 0

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient

                ScrollView {
                    Group {
                        if usesTwoColumns, let result = runner.result {
                            // Wide screens (an unfolded iPhone Duo, iPad in
                            // landscape): results beside the numbers rather
                            // than below the fold.
                            HStack(alignment: .top, spacing: 24) {
                                // Each column keeps its natural height. An
                                // HStack offers both columns the taller one's
                                // height, which the graphs would stretch to fill.
                                VStack(spacing: 28) { primaryColumn }
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: 560)
                                VStack(spacing: 28) { resultSections(result) }
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: 560)
                                    // Line the cards up with the hero card,
                                    // not with the header above it.
                                    .padding(.top, 72)
                            }
                            .frame(maxWidth: 1144)
                        } else {
                            VStack(spacing: 28) {
                                primaryColumn
                                if let result = runner.result {
                                    resultSections(result)
                                }
                            }
                            // Readable line lengths on iPad and wide Mac windows.
                            .frame(maxWidth: 640)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .padding(.top, 12)
                }
                // Screenshot mode's "details" scene opens on the cards below the fold.
                .defaultScrollAnchor(ScreenshotDemo.scene == .details ? .bottom : .top)
                .onGeometryChange(for: CGFloat.self) { proxy in
                    proxy.size.width
                } action: { width in
                    availableWidth = width
                }
            }
            .toolbar {
                ToolbarItem(placement: historyButtonPlacement) {
                    Button {
                        showHistory = true
                    } label: {
                        // A real Label even on tvOS: the nav bar names items
                        // from the Label title and ignores explicit
                        // accessibility labels, so icon-only items would
                        // read as the symbol's auto-description ("Clock
                        // with a counterclockwise triangle-headed arrow…").
                        // The title truncates behind an open sheet, a
                        // cosmetic quirk noted in TODO.
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                }
                ToolbarItem(placement: historyButtonPlacement) {
                    Menu {
                        Toggle("Start Tests Automatically", isOn: $startsAutomatically)
                        Toggle("Warn on Metered Networks", isOn: $warnsBeforeMeteredTest)
                        #if !os(tvOS)
                        Section("Not affiliated with Cloudflare") {
                            Link("Privacy Policy", destination: URL(string: "https://speed-ios-website.aashishvanand.workers.dev/privacy")!)
                        }
                        #endif
                    } label: {
                        Label("Options", systemImage: "ellipsis.circle")
                    }
                }
            }
            .sheet(isPresented: $showHistory) {
                HistoryView()
                    #if os(macOS)
                    // A List has no ideal size, so without this the sheet
                    // opens at whatever minimum macOS picks.
                    .frame(minWidth: 460, idealWidth: 520, minHeight: 480, idealHeight: 600)
                    #endif
            }
            .confirmationDialog(
                "This network may be metered",
                isPresented: $confirmingMeteredStart,
                titleVisibility: .visible
            ) {
                Button("Start Test") { runner.start() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("A full test moves as much data as this link can carry for about 16 seconds — up to around 1 GB each way on a very fast connection, far less at typical cellular speeds.")
            }
        }
        .onChange(of: connectivity.hasResolvedPath, initial: true) { _, resolved in
            // Wait for the first real path before deciding: until then the
            // expensive/constrained flags are placeholders. A full test can
            // move hundreds of MB, so it only starts by itself on an
            // unmetered link; on cellular or Low Data Mode it waits for a tap.
            guard resolved, !didConsiderAutoStart else { return }
            didConsiderAutoStart = true
            #if DEBUG
            if let scene = ScreenshotDemo.scene {
                ScreenshotDemo.apply(scene, to: runner)
                showHistory = scene == .history
                return
            }
            #endif
            if runner.phase == .idle, startsAutomatically, connectivity.allowsAutomaticTest {
                runner.start()
            }
        }
        .onChange(of: runner.phase) { oldPhase, newPhase in
            announce(newPhase, from: oldPhase)
            guard newPhase == .finished, let result = runner.result, !ScreenshotDemo.isActive else { return }
            saveHistoryEntry(for: result)
        }
        .onChange(of: connectivity.isOnline) { _, isOnline in
            // Coming back online after a failed run is the moment the user
            // wants a result, so pick the test back up rather than making
            // them notice the connection returned and tap again — as long as
            // the link it came back on isn't metered, and the failure is one
            // a returning network fixes. Retrying a 429 at once would only
            // make the rate limit worse.
            guard isOnline, case .failed(let failure) = runner.phase, failure.allowsAutomaticRetry,
                  startsAutomatically, connectivity.allowsAutomaticTest, !ScreenshotDemo.isActive else { return }
            runner.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Suspended transfers keep counting wall-clock time, so a run
                // that resumes would finish with a bogus (low) number and
                // save it to history. Abandon it and start clean on return.
                // macOS doesn't suspend a hidden or minimized app, so there
                // the run carries on.
                #if !os(macOS)
                if runner.isRunning {
                    runner.cancel()
                    resumeWhenActive = true
                }
                #endif
            case .active:
                // Only pick the run back up where an automatic start would be
                // allowed: it may have begun on Wi-Fi and be coming back on
                // cellular or in Low Data Mode. Otherwise stay idle; the
                // subtitle explains why.
                if resumeWhenActive {
                    resumeWhenActive = false
                    if startsAutomatically, connectivity.allowsAutomaticTest {
                        runner.start()
                    }
                }
            default:
                break
            }
        }
    }

    // MARK: - Layout

    /// Two columns once each can be at least as wide as a phone screen.
    /// iOS only: tvOS is designed around one centered column, and the Mac
    /// window sizes itself to its content, so a width-dependent layout there
    /// would feed back into the window size.
    private var usesTwoColumns: Bool {
        #if os(iOS)
        availableWidth >= 820
        #else
        false
        #endif
    }

    /// Header, live numbers and the action button.
    @ViewBuilder
    private var primaryColumn: some View {
        header

        VStack(spacing: 16) {
            GlassEffectContainer {
                if case .failed(let failure) = runner.phase {
                    failureCard(failure)
                } else {
                    HeroCard(runner: runner)
                }
            }
            if runner.phase == .finished || isRunning {
                GlassEffectContainer(spacing: 16) {
                    SecondaryStatsRow(runner: runner)
                }
            }
        }

        // Right under the numbers, so "Test Again" doesn't sit below every
        // result card.
        actionButton
    }

    /// The detail cards shown once a run has finished.
    @ViewBuilder
    private func resultSections(_ result: TestResult) -> some View {
        // No quality card when a metric the scoring needs went unmeasured:
        // better a missing card than a grade we can't stand behind.
        if let quality = result.quality {
            qualitySection(quality)
        }
        serverSection(result.meta)
        latencySection(result)
    }

    /// Tells VoiceOver what the run is doing at each step — but not the 5 Hz
    /// number updates, which would drown everything else out.
    private func announce(_ phase: TestPhase, from oldPhase: TestPhase) {
        let text: String
        switch phase {
        case .latency: text = "Measuring latency"
        case .download: text = "Testing download speed"
        case .upload: text = "Testing upload speed"
        case .finished:
            guard let result = runner.result else { return }
            text = "Test complete. Download \(SpeedFormat.text(result.download.p90Mbps)), upload \(SpeedFormat.text(result.upload.p90Mbps)), latency \(SpeedFormat.number(result.idleLatency.medianMs, fractionDigits: 0)) milliseconds."
        case .failed(let failure):
            text = "Test failed. \(failure.title)."
        case .idle:
            guard oldPhase != .idle, oldPhase != .finished else { return }
            if case .failed = oldPhase { return }
            text = "Test stopped"
        case .connecting:
            return
        }
        AccessibilityNotification.Announcement(text).post()
    }

    private func saveHistoryEntry(for result: TestResult) {
        let entry = TestHistoryEntry(
            downloadMbps: result.download.p90Mbps,
            uploadMbps: result.upload.p90Mbps,
            pingMs: result.idleLatency.medianMs,
            jitterMs: result.idleLatency.jitterMs,
            ispName: result.meta.ispName,
            connectionType: connectivity.connectionType
        )
        HistoryStore.record(entry, in: modelContext)
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.cfOrange.opacity(0.24), Color.platformBackground]
                : [Color.cfOrange.opacity(0.38), Color.cfOrange.opacity(0.1), Color.platformBackground],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    private var historyButtonPlacement: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarTrailing
        #endif
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text(titleText)
                .font(.title2.bold())
                // Wraps at large text sizes; keep it centered like the status line.
                .multilineTextAlignment(.center)
                .contentTransition(reduceMotion ? .identity : .opacity)
                .animation(reduceMotion ? nil : .easeInOut, value: titleText)
                .accessibilityAddTraits(.isHeader)
            // Re-evaluated every minute so "Measured 5 min ago" keeps up on a
            // Mac or Apple TV left open.
            TimelineView(.everyMinute) { context in
                let text = statusText(now: context.date)
                Text(text)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .contentTransition(reduceMotion ? .identity : .opacity)
                    .animation(reduceMotion ? nil : .easeInOut, value: text)
            }
        }
    }

    // MARK: - Failure

    /// Stands in for the hero number when a run can't produce one, keeping
    /// the same glass shape so the layout doesn't jump between states.
    private func failureCard(_ failure: TestFailure) -> some View {
        VStack(spacing: 14) {
            Image(systemName: failure.systemImage)
                .font(.system(size: 52))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.secondary)

            Text(failure.title)
                .font(.title3.bold())
                .multilineTextAlignment(.center)

            Text(failure.message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        }
        .padding(.vertical, 44)
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Network quality

    private func qualitySection(_ quality: NetworkQuality) -> some View {
        card(title: "Network Quality") {
            VStack(spacing: 10) {
                qualityRow(label: "Video Streaming", grade: quality.videoStreaming)
                Divider()
                qualityRow(label: "Online Gaming", grade: quality.onlineGaming)
                Divider()
                qualityRow(label: "Video Chatting", grade: quality.videoChatting)
            }
        }
    }

    private func qualityRow(label: String, grade: QualityGrade) -> some View {
        AdaptiveRow {
            Text(label)
        } value: {
            Text(grade.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(grade.textColor(scheme: colorScheme, contrast: colorSchemeContrast))
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: - Server location

    private func serverSection(_ meta: NetworkMeta) -> some View {
        card(title: "Server Location") {
            VStack(spacing: 10) {
                #if !os(tvOS)
                if let latitude = meta.latitude, let longitude = meta.longitude {
                    ColoMapView(
                        coordinate: CLLocationCoordinate2D(latitude: latitude, longitude: longitude),
                        title: meta.colo ?? "Server"
                    )
                    .frame(height: 150)
                    .clipShape(.rect(cornerRadius: 18))
                    // Decorative: the rows below say the same in words.
                    .accessibilityHidden(true)
                }
                #endif

                infoRow(label: "Server", value: serverLocationText(meta))
                if let country = meta.country {
                    Divider()
                    infoRow(label: "Country", value: Locale.current.localizedString(forRegionCode: country) ?? country)
                }
                if meta.ispName != nil || meta.asn != nil {
                    Divider()
                    infoRow(label: "Your network", value: networkText(meta))
                }
                if let ip = meta.clientIP {
                    Divider()
                    ipRow(ip)
                }
            }
        }
    }

    private func ipRow(_ ip: String) -> some View {
        AdaptiveRow {
            Text("Your IP").foregroundStyle(.secondary)
        } value: {
            Button(revealsIP ? ip : "Show") {
                revealsIP.toggle()
            }
            #if os(tvOS)
            .buttonStyle(.plain)
            #else
            .buttonStyle(.borderless)
            #endif
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Your IP")
        .accessibilityValue(revealsIP ? ip : "Hidden")
        .accessibilityHint(revealsIP ? "Hides the address" : "Shows the address")
    }

    private func networkText(_ meta: NetworkMeta) -> String {
        switch (meta.ispName, meta.asn) {
        case let (isp?, asn?): return "\(isp) (AS\(asn))"
        case let (isp?, nil): return isp
        case let (nil, asn?): return "AS\(asn)"
        case (nil, nil): return ""
        }
    }

    private func serverLocationText(_ meta: NetworkMeta) -> String {
        switch (meta.city, meta.colo) {
        case let (city?, colo?): return "\(city) (\(colo))"
        case let (city?, nil): return city
        case let (nil, colo?): return colo
        case (nil, nil): return ""
        }
    }

    private func infoRow(label: String, value: String) -> some View {
        AdaptiveRow {
            Text(label).foregroundStyle(.secondary)
        } value: {
            Text(value.isEmpty ? "–" : value)
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    // MARK: - Latency measurements

    private func latencySection(_ result: TestResult) -> some View {
        card(title: "Latency Measurements") {
            VStack(spacing: 10) {
                latencyRow(label: "Unloaded", summary: result.idleLatency)
                Divider()
                latencyRow(label: "During download", summary: result.downloadLoadedLatency)
                Divider()
                latencyRow(label: "During upload", summary: result.uploadLoadedLatency)
            }
        }
    }

    private func latencyRow(label: String, summary: LatencySummary?) -> some View {
        AdaptiveRow {
            Text(label).foregroundStyle(.secondary)
        } value: {
            if let summary {
                Text(latencyText(summary))
                    .monospacedDigit()
            } else {
                Text("Not measured")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .accessibilityElement(children: .combine)
    }

    private func latencyText(_ summary: LatencySummary) -> String {
        let average = "\(SpeedFormat.milliseconds(summary.avgMs, fractionDigits: 1)) avg"
        guard let jitter = summary.jitterMs else { return average }
        return "\(average) · \(SpeedFormat.milliseconds(jitter, fractionDigits: 1)) jitter"
    }

    // MARK: - Shared card container

    private func card<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)
            content()
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        #if os(tvOS)
        // A tvOS ScrollView only scrolls to focusable content, so without
        // this the cards below the fold can't be reached with the remote.
        .focusable()
        #endif
    }

    // MARK: - Action button

    @ViewBuilder
    private var actionButton: some View {
        if isRunning {
            Button(role: .cancel) {
                resumeWhenActive = false
                runner.cancel()
            } label: {
                Text("Cancel")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.glass)
            .padding(.horizontal, 40)
        } else {
            Button(action: requestStart) {
                Text(actionButtonTitle)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 24)
            }
            .buttonStyle(.glassProminent)
            .padding(.horizontal, 40)
        }
    }

    /// A deliberate tap bypasses every automatic-start guard, so metered
    /// links get one pause before the data moves.
    private func requestStart() {
        if needsMeteredWarning {
            confirmingMeteredStart = true
        } else {
            runner.start()
        }
    }

    /// The OS flags cellular, personal hotspots and Low Data Mode — the
    /// same links `allowsAutomaticTest` refuses. It can't see capped home
    /// or satellite links, so this is a floor on which taps get warned, not
    /// a ceiling; the result subtitle always shows the data actually used.
    private var needsMeteredWarning: Bool {
        warnsBeforeMeteredTest && connectivity.hasResolvedPath && connectivity.isOnline
            && (connectivity.isExpensive || connectivity.isConstrained)
    }

    private var actionButtonTitle: String {
        switch runner.phase {
        case .failed: return "Try Again"
        case .finished: return "Test Again"
        default: return "Start Test"
        }
    }

    private var isRunning: Bool { runner.isRunning }

    /// How to start a test, in the platform's own words.
    private static var startPrompt: String {
        #if os(macOS)
        "click Start Test"
        #elseif os(tvOS)
        "select Start Test"
        #else
        "tap to test"
        #endif
    }

    /// Header title tracks the run: an invitation before, live narration
    /// during, and a summary label once results are on screen.
    private var titleText: String {
        switch runner.phase {
        case .idle, .failed: return "Speed Test"
        case .finished: return "Speed Test Result"
        default: return "Testing Network Speed…"
        }
    }

    private func statusText(now: Date) -> String {
        switch runner.phase {
        case .idle:
            // Explain why nothing happened on launch rather than leaving the
            // user to wonder whether the app is broken.
            if connectivity.hasResolvedPath, !connectivity.isOnline {
                return "You're offline — connect to run a test"
            }
            if didConsiderAutoStart, connectivity.hasResolvedPath, !connectivity.allowsAutomaticTest {
                return connectivity.isConstrained
                    ? "Low Data Mode is on — \(Self.startPrompt)"
                    : "On a metered connection — \(Self.startPrompt)"
            }
            return "Ready to test"
        case .connecting: return "Finding the nearest server…"
        case .latency: return "Measuring latency…"
        case .download: return "Testing download speed…"
        case .upload: return "Testing upload speed…"
        case .finished:
            guard let result = runner.result else { return "Measured just now" }
            let when = now.timeIntervalSince(result.date) < 60
                ? "Measured just now"
                : "Measured \(result.date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)))"
            return "\(when) · \(SpeedFormat.bytes(result.bytesTransferred)) used"
        // The card below carries the title and the explanation, so the
        // subtitle stays short rather than repeating either.
        case .failed: return "Test couldn't complete"
        }
    }
}

// MARK: - Live cards
//
// Split out of `SpeedTestView` so Observation scopes the 5 Hz tick updates to
// these two views: only their bodies read the per-tick properties
// (`downloadMbps`, samples, `latencyMs`), so the rest of the screen isn't
// re-evaluated on every tick.

/// The big number with the live throughput graph behind it.
private struct HeroCard: View {
    let runner: SpeedTestRunner
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Scales with Dynamic Type, unlike a fixed point size.
    @ScaledMetric(relativeTo: .largeTitle) private var valueFontSize: CGFloat = 72

    var body: some View {
        ZStack {
            ThroughputGraph(samples: heroSamples, color: heroGraphColor, blurred: runner.phase == .finished)
                .clipShape(.rect(cornerRadius: 32))

            VStack(spacing: 6) {
                Image(systemName: heroIcon)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(heroValueText)
                    .font(.system(size: valueFontSize, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(reduceMotion ? .identity : .numericText())
                    // Live ticks arrive every 200 ms; a spring per tick would stack
                    // animations faster than they finish. A short linear
                    // roll keeps the digits readable without the churn.
                    .animation(reduceMotion ? nil : .linear(duration: 0.15), value: heroValueText)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

                Text(heroUnitText)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)

                Text(heroLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)

                if runner.phase == .finished {
                    Text("90th percentile")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                }
            }
            .padding(.vertical, 32)
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
        // One element: "Download, 412 Mbps", not five fragments.
        .accessibilityElement(children: .ignore)
        .accessibilityLabelAndValue(accessibilityLabelText, accessibilityValueText)
        .accessibilityAddTraits(.updatesFrequently)
    }

    private var accessibilityLabelText: String {
        switch runner.phase {
        case .connecting, .latency: return "Ping"
        case .download: return "Download"
        case .upload: return "Upload"
        case .finished: return "Download, 90th percentile"
        default: return "Speed"
        }
    }

    private var accessibilityValueText: String {
        heroValueText == "—" ? "Pending" : "\(heroValueText) \(heroUnitText)"
    }

    private var heroSamples: [Double] {
        switch runner.phase {
        case .download: return runner.downloadSamples
        case .upload: return runner.uploadSamples
        case .finished: return runner.downloadSamples
        default: return []
        }
    }

    private var heroGraphColor: Color {
        switch runner.phase {
        case .upload: return .purple
        default: return .blue
        }
    }

    private var heroIcon: String {
        switch runner.phase {
        case .connecting, .latency: return "dot.radiowaves.left.and.right"
        case .download: return "arrow.down.circle"
        case .upload: return "arrow.up.circle"
        case .finished: return "checkmark.circle"
        // Nothing has been measured, so nothing to tick off.
        default: return "gauge.with.needle"
        }
    }

    private var heroLabel: String {
        switch runner.phase {
        case .connecting, .latency: return "Ping"
        case .download: return "Download"
        case .upload: return "Upload"
        case .finished: return "Download"
        default: return " "
        }
    }

    private var heroValueText: String {
        switch runner.phase {
        case .connecting, .latency:
            // Nothing measured yet reads as pending, not as a 0 ms ping.
            return runner.latencyMs > 0 ? SpeedFormat.number(runner.latencyMs, fractionDigits: 0) : "—"
        case .download:
            return runner.downloadSamples.isEmpty ? "—" : SpeedFormat.value(runner.downloadMbps)
        case .upload:
            return runner.uploadSamples.isEmpty ? "—" : SpeedFormat.value(runner.uploadMbps)
        case .finished:
            return SpeedFormat.value(runner.result?.download.p90Mbps ?? 0)
        default:
            return "—"
        }
    }

    private var heroUnitText: String {
        switch runner.phase {
        case .connecting, .latency: return "ms"
        case .download: return SpeedFormat.unit(runner.downloadMbps)
        case .upload: return SpeedFormat.unit(runner.uploadMbps)
        case .finished: return SpeedFormat.unit(runner.result?.download.p90Mbps ?? 0)
        default: return ""
        }
    }
}

/// Upload / latency / jitter chips under the hero card.
private struct SecondaryStatsRow: View {
    let runner: SpeedTestRunner
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// "Not measured yet", distinct from a real zero.
    private static let pending = "—"

    var body: some View {
        // Side by side normally; stacked at accessibility text sizes, where
        // three chips can't share one row legibly.
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(spacing: 12))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            statChip(icon: "arrow.up.circle", label: "Upload", value: chipUploadText, samples: runner.phase == .finished ? runner.uploadSamples : [], graphColor: .purple)
            statChip(icon: "timer", label: latencyLabel, value: chipLatencyText)
            statChip(icon: "waveform.path", label: "Jitter", value: chipJitterText)
        }
    }

    private var chipUploadText: String {
        if let result = runner.result {
            return SpeedFormat.text(result.upload.p90Mbps)
        }
        if runner.phase == .upload, !runner.uploadSamples.isEmpty {
            return SpeedFormat.text(runner.uploadMbps)
        }
        return Self.pending
    }

    /// While transfers run, the live number is latency *under load*; once the
    /// run is done the chip shows the idle median. Say which.
    private var latencyLabel: String {
        switch runner.phase {
        case .download, .upload: return "Loaded Latency"
        case .finished: return "Idle Latency"
        default: return "Latency"
        }
    }

    private var chipLatencyText: String {
        if let result = runner.result {
            return SpeedFormat.milliseconds(result.idleLatency.medianMs)
        }
        return runner.latencyMs > 0 ? SpeedFormat.milliseconds(runner.latencyMs) : Self.pending
    }

    private var chipJitterText: String {
        // No jitter from a single latency sample: pending, not 0 ms.
        guard let jitter = runner.result?.idleLatency.jitterMs else { return Self.pending }
        return SpeedFormat.milliseconds(jitter, fractionDigits: 1)
    }

    private func statChip(icon: String, label: String, value: String, samples: [Double] = [], graphColor: Color? = nil) -> some View {
        ZStack {
            if let graphColor, !samples.isEmpty {
                ThroughputGraph(samples: samples, color: graphColor, blurred: true)
                    .clipShape(.rect(cornerRadius: 20))
            }

            VStack(spacing: 4) {
                Image(systemName: icon)
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.headline)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(reduceMotion ? .identity : .numericText())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.vertical, 14)
            .padding(.horizontal, 6)
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
        .accessibilityElement(children: .ignore)
        .accessibilityLabelAndValue(label, value == Self.pending ? "Pending" : value)
    }
}

/// A label/value row that sits side by side when it fits and stacks when it
/// doesn't — long ISP names, narrow phones, accessibility text sizes.
private struct AdaptiveRow<Label: View, Value: View>: View {
    @ViewBuilder var label: Label
    @ViewBuilder var value: Value

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                label
                Spacer(minLength: 12)
                value
                    .multilineTextAlignment(.trailing)
            }
            VStack(alignment: .leading, spacing: 2) {
                label
                value
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Live area+line sparkline of instantaneous Mbps samples, meant to sit
/// behind a glass card's number — the "speedtest feel" of a graph growing
/// in real time as the test runs, like speed.cloudflare.com's own result
/// charts. Hand-drawn with Canvas rather than Swift Charts: at a 200ms tick
/// rate Charts was rebuilding a full mark/legend/axis view tree every tick
/// (all overhead we don't need for an unlabeled sparkline), and a fixed
/// per-tick `.animation` shorter than the tick interval was stacking
/// animations faster than they could finish. Canvas is immediate-mode — one
/// cheap path fill+stroke per frame — and still composites via Core
/// Animation's normal Metal-backed layer tree, so there's nothing a
/// hand-rolled Metal renderer would meaningfully speed up here.
private struct ThroughputGraph: View {
    let samples: [Double]
    let color: Color
    var blurred: Bool = false

    var body: some View {
        Canvas { context, size in
            guard samples.count > 1 else { return }
            let maxValue = max(samples.max() ?? 1, 1) * 1.25
            let stepX = size.width / CGFloat(samples.count - 1)
            let points = samples.enumerated().map { index, value in
                CGPoint(x: CGFloat(index) * stepX, y: size.height * (1 - CGFloat(value / maxValue)))
            }

            let line = smoothPath(through: points)
            var area = line
            area.addLine(to: CGPoint(x: points[points.count - 1].x, y: size.height))
            area.addLine(to: CGPoint(x: points[0].x, y: size.height))
            area.closeSubpath()

            context.fill(
                area,
                with: .linearGradient(
                    Gradient(colors: [color.opacity(0.28), color.opacity(0.02)]),
                    startPoint: CGPoint(x: 0, y: 0),
                    endPoint: CGPoint(x: 0, y: size.height)
                )
            )
            context.stroke(
                line,
                with: .color(color.opacity(blurred ? 0.85 : 0.7)),
                lineWidth: blurred ? 2.5 : 2
            )
        }
        .blur(radius: blurred ? 6 : 0)
    }

    /// Quadratic-curve-through-midpoints smoothing — a lightweight stand-in
    /// for Swift Charts' catmullRom interpolation.
    private func smoothPath(through points: [CGPoint]) -> Path {
        var path = Path()
        path.move(to: points[0])
        for i in 1..<points.count {
            let mid = CGPoint(x: (points[i - 1].x + points[i].x) / 2, y: (points[i - 1].y + points[i].y) / 2)
            path.addQuadCurve(to: mid, control: points[i - 1])
        }
        path.addLine(to: points[points.count - 1])
        return path
    }
}

#if !os(tvOS)
/// Static, non-interactive map pin at the colo's coordinates — matches the
/// "Server Location" map on speed.cloudflare.com's own results page.
private struct ColoMapView: View {
    let coordinate: CLLocationCoordinate2D
    let title: String

    var body: some View {
        Map(
            initialPosition: .region(
                MKCoordinateRegion(center: coordinate, span: MKCoordinateSpan(latitudeDelta: 0.15, longitudeDelta: 0.15))
            ),
            interactionModes: []
        ) {
            Marker(title, coordinate: coordinate)
                .tint(Color.cfOrange)
        }
        .mapStyle(.standard(pointsOfInterest: .excludingAll))
        .allowsHitTesting(false)
    }
}
#endif

private extension Color {
    static let cfOrange = Color(red: 246 / 255, green: 130 / 255, blue: 31 / 255)

    static var platformBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #elseif os(tvOS)
        .black
        #else
        Color(uiColor: .systemBackground)
        #endif
    }
}

#Preview {
    SpeedTestView()
        .modelContainer(HistoryStore.previewContainer())
}
