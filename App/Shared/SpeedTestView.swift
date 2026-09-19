import SwiftUI
import CFSpeedKit

struct SpeedTestView: View {
    @StateObject private var runner = SpeedTestRunner()

    var body: some View {
        VStack(spacing: 32) {
            Text("CF Speed Test")
                .font(.largeTitle.bold())

            VStack(spacing: 8) {
                metricRow(label: "Ping", value: String(format: "%.0f ms", runner.latencyMs))
                metricRow(label: "Download", value: String(format: "%.1f Mbps", runner.downloadMbps))
                metricRow(label: "Upload", value: String(format: "%.1f Mbps", runner.uploadMbps))
            }
            .font(.title2)

            statusLabel

            if let result = runner.result {
                resultSummary(result)
            }

            Button(action: runner.start) {
                Text(isRunning ? "Testing…" : "Start Test")
                    .font(.title3.bold())
                    .frame(minWidth: 220, minHeight: 48)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isRunning)

            if !runner.meta.isEmptyDisplay {
                metaFooter
            }
        }
        .padding(40)
    }

    private var isRunning: Bool {
        switch runner.phase {
        case .idle, .finished, .failed:
            return false
        default:
            return true
        }
    }

    private var statusLabel: some View {
        Text(statusText)
            .font(.headline)
            .foregroundStyle(.secondary)
    }

    private var statusText: String {
        switch runner.phase {
        case .idle: return "Ready"
        case .connecting: return "Connecting to Cloudflare…"
        case .latency: return "Measuring latency…"
        case .download: return "Testing download…"
        case .upload: return "Testing upload…"
        case .finished: return "Done"
        case .failed(let message): return "Failed: \(message)"
        }
    }

    private func metricRow(label: String, value: String) -> some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .frame(maxWidth: 360)
    }

    private func resultSummary(_ result: TestResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Idle latency: \(String(format: "%.0f", result.idleLatency.avgMs)) ms (jitter \(String(format: "%.0f", result.idleLatency.jitterMs)) ms)")
            Text("Download: \(String(format: "%.1f", result.download.meanMbps)) Mbps (median \(String(format: "%.1f", result.download.medianMbps)))")
            Text("Upload: \(String(format: "%.1f", result.upload.meanMbps)) Mbps (median \(String(format: "%.1f", result.upload.medianMbps)))")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var metaFooter: some View {
        VStack(spacing: 2) {
            if let colo = runner.meta.colo {
                Text("Server: \(colo)")
            }
            if let ip = runner.meta.clientIP {
                Text("Your IP: \(ip)")
            }
        }
        .font(.caption2)
        .foregroundStyle(.tertiary)
    }
}

private extension NetworkMeta {
    var isEmptyDisplay: Bool {
        clientIP == nil && colo == nil
    }
}

#Preview {
    SpeedTestView()
}
