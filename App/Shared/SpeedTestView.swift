import SwiftUI
import UIKit
import Charts
#if !os(tvOS)
import MapKit
#endif
import CFSpeedKit

struct SpeedTestView: View {
    @StateObject private var runner = SpeedTestRunner()
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            backgroundGradient

            ScrollView {
                VStack(spacing: 28) {
                    header

                    GlassEffectContainer(spacing: 16) {
                        heroCard
                        if runner.phase == .finished || isRunning {
                            secondaryStatsRow
                        }
                    }

                    if let result = runner.result {
                        qualitySection(result.quality)
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
        .task {
            if runner.phase == .idle {
                runner.start()
            }
        }
    }

    // MARK: - Background

    private var backgroundGradient: some View {
        LinearGradient(
            colors: colorScheme == .dark
                ? [Color.cfOrange.opacity(0.24), Color(uiColor: .platformBackground)]
                : [Color.cfOrange.opacity(0.38), Color.cfOrange.opacity(0.1), Color(uiColor: .platformBackground)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
        .ignoresSafeArea()
    }

    // MARK: - Header

    private var header: some View {
        VStack(spacing: 4) {
            Text("Speed Test")
                .font(.title2.bold())
            Text(statusText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
                .animation(.easeInOut, value: statusText)
        }
    }

    // MARK: - Hero

    private var heroCard: some View {
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
                    .animation(.snappy, value: heroValueText)
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
            return Formatting.speedValue(runner.result?.download.meanMbps ?? 0)
        default:
            return "–"
        }
    }

    private var heroUnitText: String {
        switch runner.phase {
        case .connecting, .latency: return "ms"
        case .download: return Formatting.speedUnit(runner.downloadMbps)
        case .upload: return Formatting.speedUnit(runner.uploadMbps)
        case .finished: return Formatting.speedUnit(runner.result?.download.meanMbps ?? 0)
        default: return ""
        }
    }

    // MARK: - Secondary stats (upload / latency / jitter chips)

    private var secondaryStatsRow: some View {
        HStack(spacing: 12) {
            statChip(icon: "arrow.up.circle", label: "Upload", value: chipUploadText, samples: runner.phase == .finished ? runner.uploadSamples : [], graphColor: .purple)
            statChip(icon: "timer", label: "Latency", value: chipLatencyText)
            statChip(icon: "waveform.path", label: "Jitter", value: chipJitterText)
        }
    }

    private var chipUploadText: String {
        let mbps = runner.result?.upload.meanMbps ?? (runner.phase == .upload ? runner.uploadMbps : 0)
        return "\(Formatting.speedValue(mbps)) \(Formatting.speedUnit(mbps))"
    }

    private var chipLatencyText: String {
        let ms = runner.result?.idleLatency.avgMs ?? runner.latencyMs
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
        case .fair: return .orange
        case .poor: return .red
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

    private func latencyRow(label: String, summary: LatencySummary) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(String(format: "%.1f ms avg · %.1f ms jitter", summary.avgMs, summary.jitterMs))
                .monospacedDigit()
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
            Text(isRunning ? "Testing…" : "Test Again")
                .font(.headline)
                .frame(maxWidth: .infinity, minHeight: 24)
        }
        .buttonStyle(.glassProminent)
        .disabled(isRunning)
        .padding(.horizontal, 40)
    }

    private var isRunning: Bool {
        switch runner.phase {
        case .idle, .finished, .failed:
            return false
        default:
            return true
        }
    }

    private var statusText: String {
        switch runner.phase {
        case .idle: return "Ready to test"
        case .connecting: return "Finding the nearest server…"
        case .latency: return "Measuring latency…"
        case .download: return "Testing download speed…"
        case .upload: return "Testing upload speed…"
        case .finished: return "Measured just now"
        case .failed(let message): return "Failed: \(message)"
        }
    }
}

/// Live area+line chart of instantaneous Mbps samples, meant to sit behind a
/// glass card's number — the "speedtest feel" of a graph growing in real
/// time as the test runs, like speed.cloudflare.com's own result charts.
private struct ThroughputGraph: View {
    let samples: [Double]
    let color: Color
    var blurred: Bool = false

    var body: some View {
        Chart {
            ForEach(Array(samples.enumerated()), id: \.offset) { index, value in
                AreaMark(x: .value("Tick", index), y: .value("Mbps", value))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [color.opacity(0.28), color.opacity(0.02)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .interpolationMethod(.catmullRom)

                LineMark(x: .value("Tick", index), y: .value("Mbps", value))
                    .foregroundStyle(color.opacity(blurred ? 0.85 : 0.7))
                    .lineStyle(StrokeStyle(lineWidth: blurred ? 2.5 : 2))
                    .interpolationMethod(.catmullRom)
            }
        }
        .chartXAxis(.hidden)
        .chartYAxis(.hidden)
        .chartYScale(domain: 0...max((samples.max() ?? 1) * 1.25, 1))
        .chartLegend(.hidden)
        .blur(radius: blurred ? 6 : 0)
        .animation(.easeOut(duration: 0.25), value: samples)
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
}

private extension UIColor {
    static var platformBackground: UIColor {
        #if os(tvOS)
        .black
        #else
        .systemBackground
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
}
