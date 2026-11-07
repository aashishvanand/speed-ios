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
    @Environment(\.modelContext) private var modelContext
    @Environment(\.scenePhase) private var scenePhase
    @State private var showHistory = false
    /// The launch-time automatic run is attempted once per launch, as soon as
    /// the network path is known.
    @State private var didConsiderAutoStart = false
    /// A run cut short by backgrounding, to pick back up on return.
    @State private var resumeWhenActive = false

    var body: some View {
        NavigationStack {
            ZStack {
                backgroundGradient

                ScrollView {
                    VStack(spacing: 28) {
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

                        if let result = runner.result {
                            // No quality card when a metric the scoring
                            // needs went unmeasured — better a missing card
                            // than a grade we can't stand behind.
                            if let quality = result.quality {
                                qualitySection(quality)
                            }
                            serverSection(result.meta)
                            latencySection(result)
                        }

                        actionButton
                            .padding(.top, runner.result == nil ? 8 : 0)
                    }
                    .padding(20)
                    .padding(.top, 12)
                }
            }
            .toolbar {
                ToolbarItem(placement: historyButtonPlacement) {
                    Button {
                        showHistory = true
                    } label: {
                        Image(systemName: "clock.arrow.circlepath")
                    }
                }
            }
            .sheet(isPresented: $showHistory) {
                HistoryView()
            }
        }
        .onChange(of: connectivity.hasResolvedPath, initial: true) { _, resolved in
            // Wait for the first real path before deciding: until then the
            // expensive/constrained flags are placeholders. A full test can
            // move hundreds of MB, so it only starts by itself on an
            // unmetered link; on cellular or Low Data Mode it waits for a tap.
            guard resolved, !didConsiderAutoStart else { return }
            didConsiderAutoStart = true
            if runner.phase == .idle, connectivity.allowsAutomaticTest {
                runner.start()
            }
        }
        .onChange(of: runner.phase) { _, newPhase in
            guard newPhase == .finished, let result = runner.result else { return }
            saveHistoryEntry(for: result)
        }
        .onChange(of: connectivity.isOnline) { _, isOnline in
            // Coming back online after a failed run is the moment the user
            // wants a result, so pick the test back up rather than making
            // them notice the connection returned and tap again — as long as
            // the link it came back on isn't metered.
            guard isOnline, case .failed = runner.phase, connectivity.allowsAutomaticTest else { return }
            runner.start()
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .background:
                // Suspended transfers keep counting wall-clock time, so a run
                // that resumes would finish with a bogus (low) number and
                // save it to history. Abandon it and start clean on return.
                if runner.isRunning {
                    runner.cancel()
                    resumeWhenActive = true
                }
            case .active:
                if resumeWhenActive {
                    resumeWhenActive = false
                    runner.start()
                }
            default:
                break
            }
        }
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
                .contentTransition(.opacity)
                .animation(.easeInOut, value: titleText)
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut, value: statusText)
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
        HStack {
            Text(label)
            Spacer()
            Text(grade.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(gradeColor(grade))
        }
    }

    private func gradeColor(_ grade: QualityGrade) -> Color {
        switch grade {
        case .great: return .green
        case .good: return .blue
        case .average: return .yellow
        case .poor: return .orange
        case .bad: return .red
        }
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
                }
                #endif

                infoRow(label: "Server", value: serverLocationText(meta))
                if let country = meta.country {
                    Divider()
                    infoRow(label: "Country", value: country)
                }
                if meta.ispName != nil || meta.asn != nil {
                    Divider()
                    infoRow(label: "Your network", value: networkText(meta))
                }
                if let ip = meta.clientIP {
                    Divider()
                    infoRow(label: "Your IP", value: ip)
                }
            }
        }
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
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value.isEmpty ? "–" : value)
                .multilineTextAlignment(.trailing)
        }
        .font(.subheadline)
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
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            if let summary {
                Text(String(format: "%.1f ms avg · %.1f ms jitter", summary.avgMs, summary.jitterMs))
                    .monospacedDigit()
            } else {
                Text("Not measured")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.subheadline)
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
    }

    // MARK: - Action button

    private var actionButton: some View {
        Button(action: runner.start) {
            Text(actionButtonTitle)
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.glassProminent)
        .disabled(isRunning)
        .padding(.horizontal, 40)
    }

    private var actionButtonTitle: String {
        switch runner.phase {
        case .idle: return "Start Test"
        case .failed: return "Try Again"
        default: return isRunning ? "Testing…" : "Test Again"
        }
    }

    private var isRunning: Bool { runner.isRunning }

    /// Header title tracks the run: an invitation before, live narration
    /// during, and a summary label once results are on screen.
    private var titleText: String {
        switch runner.phase {
        case .idle, .failed: return "Speed Test"
        case .finished: return "Speed Test Result"
        default: return "Testing Network Speed…"
        }
    }

    private var statusText: String {
        switch runner.phase {
        case .idle:
            // Explain why nothing happened on launch rather than leaving the
            // user to wonder whether the app is broken.
            if didConsiderAutoStart, connectivity.hasResolvedPath, !connectivity.allowsAutomaticTest, connectivity.isOnline {
                return connectivity.isConstrained
                    ? "Low Data Mode is on — tap to test"
                    : "On a metered connection — tap to test"
            }
            return "Ready to test"
        case .connecting: return "Finding the nearest server…"
        case .latency: return "Measuring latency…"
        case .download: return "Testing download speed…"
        case .upload: return "Testing upload speed…"
        case .finished: return "Measured just now"
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

    var body: some View {
        ZStack {
            ThroughputGraph(samples: heroSamples, color: heroGraphColor, blurred: runner.phase == .finished)
                .clipShape(.rect(cornerRadius: 32))

            VStack(spacing: 6) {
                Image(systemName: heroIcon)
                    .font(.title3)
                    .foregroundStyle(.secondary)

                Text(heroValueText)
                    .font(.system(size: 72, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    // Live ticks arrive every 200 ms; a spring per tick would stack
                    // animations faster than they finish. A short linear
                    // roll keeps the digits readable without the churn.
                    .animation(.linear(duration: 0.15), value: heroValueText)
                    .minimumScaleFactor(0.5)
                    .lineLimit(1)
                    .shadow(color: .black.opacity(0.18), radius: 6, y: 2)

                Text(heroUnitText)
                    .font(.title3.weight(.medium))
                    .foregroundStyle(.secondary)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)

                Text(heroLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
                    .textCase(.uppercase)
                    .shadow(color: .black.opacity(0.12), radius: 4, y: 1)

                if runner.phase == .finished {
                    Text("90th percentile")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .shadow(color: .black.opacity(0.1), radius: 3, y: 1)
                }
            }
            .padding(.vertical, 32)
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 32))
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
        default: return "checkmark.circle"
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
            return String(format: "%.0f", runner.latencyMs)
        case .download:
            return Formatting.speedValue(runner.downloadMbps)
        case .upload:
            return Formatting.speedValue(runner.uploadMbps)
        case .finished:
            return Formatting.speedValue(runner.result?.download.p90Mbps ?? 0)
        default:
            return "–"
        }
    }

    private var heroUnitText: String {
        switch runner.phase {
        case .connecting, .latency: return "ms"
        case .download: return Formatting.speedUnit(runner.downloadMbps)
        case .upload: return Formatting.speedUnit(runner.uploadMbps)
        case .finished: return Formatting.speedUnit(runner.result?.download.p90Mbps ?? 0)
        default: return ""
        }
    }
}

/// Upload / latency / jitter chips under the hero card.
private struct SecondaryStatsRow: View {
    let runner: SpeedTestRunner

    var body: some View {
        HStack(spacing: 12) {
            statChip(icon: "arrow.up.circle", label: "Upload", value: chipUploadText, samples: runner.phase == .finished ? runner.uploadSamples : [], graphColor: .purple)
            statChip(icon: "timer", label: "Latency", value: chipLatencyText)
            statChip(icon: "waveform.path", label: "Jitter", value: chipJitterText)
        }
    }

    private var chipUploadText: String {
        let mbps = runner.result?.upload.p90Mbps ?? (runner.phase == .upload ? runner.uploadMbps : 0)
        return "\(Formatting.speedValue(mbps)) \(Formatting.speedUnit(mbps))"
    }

    private var chipLatencyText: String {
        let ms = runner.result?.idleLatency.medianMs ?? runner.latencyMs
        return String(format: "%.0f ms", ms)
    }

    private var chipJitterText: String {
        let ms = runner.result?.idleLatency.jitterMs ?? 0
        return String(format: "%.1f ms", ms)
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
                    .contentTransition(.numericText())
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            .padding(.vertical, 14)
        }
        .frame(maxWidth: .infinity)
        .glassEffect(.regular, in: .rect(cornerRadius: 20))
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

private enum Formatting {
    static func speedValue(_ mbps: Double) -> String {
        if mbps >= 1000 {
            return String(format: "%.2g", mbps / 1000)
        }
        return String(format: "%.0f", mbps)
    }

    static func speedUnit(_ mbps: Double) -> String {
        mbps >= 1000 ? "Gbps" : "Mbps"
    }
}

#Preview {
    SpeedTestView()
        .modelContainer(HistoryStore.previewContainer())
}
