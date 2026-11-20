import SwiftUI
import SwiftData
import CFSpeedKit

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TestHistoryEntry.date, order: .reverse) private var entries: [TestHistoryEntry]
    @State private var confirmingClearAll = false
    /// The CSV of every entry, on disk, so the share sheet can hand the
    /// system a real file. Rewritten whenever a row is added or removed.
    @State private var exportURL: URL?
    private let health = HistoryHealth.shared

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    ContentUnavailableView(
                        "No Results Yet",
                        systemImage: "clock.arrow.circlepath",
                        description: Text("Run a speed test to see your history here.")
                    )
                } else {
                    List {
                        Section {
                            ForEach(entries) { entry in
                                NavigationLink {
                                    HistoryDetailView(entry: entry)
                                } label: {
                                    row(entry)
                                }
                                #if !os(tvOS)
                                .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                    Button(role: .destructive) {
                                        delete(entry)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                #else
                                // tvOS has no swipe, and `.onDelete` needs
                                // edit mode; a long press on the remote
                                // opens this menu.
                                .contextMenu {
                                    Button(role: .destructive) {
                                        delete(entry)
                                    } label: {
                                        Label("Delete", systemImage: "trash")
                                    }
                                }
                                #endif
                            }
                        } footer: {
                            VStack(alignment: .leading, spacing: 12) {
                                Text("Only your latest \(HistoryStore.retentionLimit) results are kept. Older ones are removed automatically.")
                                aboutFooter
                            }
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                VStack(spacing: 0) {
                    #if os(tvOS)
                    // tvOS crushes a nav-bar title between Done and Clear
                    // All down to "•••", so the title lives in the content.
                    Text("History")
                        .font(.title2.bold())
                        .frame(maxWidth: .infinity)
                        .padding(.bottom, 12)
                    #endif
                    healthBanner
                }
            }
            #if !os(tvOS)
            .navigationTitle("History")
            #endif
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                if !entries.isEmpty {
                    ToolbarItem(placement: .destructiveAction) {
                        Button("Clear All", role: .destructive) { confirmingClearAll = true }
                    }
                    #if !os(tvOS)
                    // tvOS has no share sheet to hand a file to.
                    if let exportURL {
                        ToolbarItem(placement: .primaryAction) {
                            ShareLink("Export", item: exportURL)
                        }
                    }
                    #endif
                }
            }
            .confirmationDialog(
                "Delete all \(entries.count) results?",
                isPresented: $confirmingClearAll,
                titleVisibility: .visible
            ) {
                Button("Delete All", role: .destructive) { clearAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This can't be undone.")
            }
            #if !os(tvOS)
            .task(id: entries.count) {
                exportURL = try? writeCSVFile(named: "Edge Speed History.csv", historyCSV(entries))
            }
            #endif
        }
    }

    /// Edge Speed borrows Cloudflare's name and colour, so say plainly that
    /// it isn't theirs, next to where the data goes.
    private var aboutFooter: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Edge Speed is an independent app. It isn't affiliated with or endorsed by Cloudflare. Tests run against speed.cloudflare.com, which receives your IP address and the measurements.")
            #if !os(tvOS)
            Link("Privacy Policy", destination: Self.privacyPolicyURL)
            #else
            Text("Privacy policy: \(Self.privacyPolicyURL.absoluteString)")
            #endif
        }
    }

    // A static literal, so it can't fail.
    private static let privacyPolicyURL = URL(string: "https://speed-ios-website.aashishvanand.workers.dev/privacy")!

    /// Persistence problems are otherwise only in the log, where nobody whose
    /// results are going missing will ever see them.
    @ViewBuilder
    private var healthBanner: some View {
        if let message = healthMessage {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow.opacity(0.15), in: .rect(cornerRadius: 12))
                .padding(.horizontal)
                .padding(.bottom, 8)
        }
    }

    private var healthMessage: String? {
        if health.isUsingTemporaryStore {
            return "History couldn't be opened, so results are only kept until the app quits."
        }
        if health.didResetUnreadableStore {
            return "Your earlier history couldn't be read, so it was reset."
        }
        if let error = health.lastError {
            return "Couldn't save history: \(error)"
        }
        return nil
    }

    private func row(_ entry: TestHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Connection and date side by side, stacked at large text sizes
            // rather than breaking words like "Ethernet" mid-word.
            ViewThatFits(in: .horizontal) {
                HStack {
                    connectionLabel(entry).fixedSize()
                    Spacer()
                    dateText(entry).fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    connectionLabel(entry)
                    dateText(entry).fixedSize(horizontal: false, vertical: true)
                }
            }

            // Side by side when they fit, stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { metrics(entry) }
                VStack(alignment: .leading, spacing: 4) { metrics(entry, fixed: false) }
            }

            if let isp = entry.ispName, !isp.isEmpty {
                Text(isp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func metrics(_ entry: TestHistoryEntry, fixed: Bool = true) -> some View {
        metric(icon: "arrow.down.circle", name: "Download", value: SpeedFormat.text(entry.downloadMbps), fixed: fixed)
        metric(icon: "arrow.up.circle", name: "Upload", value: SpeedFormat.text(entry.uploadMbps), fixed: fixed)
        metric(icon: "timer", name: "Latency", value: SpeedFormat.milliseconds(entry.pingMs), fixed: fixed)
        if let jitter = entry.jitterMs {
            metric(icon: "waveform.path", name: "Jitter", value: SpeedFormat.milliseconds(jitter, fractionDigits: 1), fixed: fixed)
        }
    }

    private func connectionLabel(_ entry: TestHistoryEntry) -> some View {
        HStack(spacing: 6) {
            Image(systemName: connectionIcon(entry.connectionType))
            Text(entry.connectionType.displayName)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
    }

    private func dateText(_ entry: TestHistoryEntry) -> some View {
        Text(entry.date, format: .dateTime.month().day().year().hour().minute())
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private func metric(icon: String, name: String, value: String, fixed: Bool) -> some View {
        // Plain HStack rather than Label: fixed at its ideal size so a value
        // like "2.45 Gbps" never wraps mid-value. If the row is too narrow,
        // ViewThatFits falls back to the stacked layout instead.
        HStack(spacing: 6) {
            Image(systemName: icon)
                .foregroundStyle(.tint)
            Text(value)
        }
        .font(.subheadline.weight(.medium))
        .monospacedDigit()
        // Stacked rows (the last resort) may wrap rather than overflow.
        .fixedSize(horizontal: fixed, vertical: fixed)
        // The icon alone means nothing to VoiceOver: "Download, 100 Mbps".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(name)
        .accessibilityValue(value)
    }

    private func connectionIcon(_ type: ConnectionType) -> String {
        switch type {
        case .wifi: return "wifi"
        case .cellular: return "antenna.radiowaves.left.and.right"
        case .wiredEthernet: return "cable.connector"
        case .other, .unknown: return "network"
        }
    }

    private func delete(_ entry: TestHistoryEntry) {
        HistoryStore.delete([entry], in: modelContext)
    }

    private func clearAll() {
        HistoryStore.deleteAll(in: modelContext)
    }
}

/// One saved result at reading size: every stored metric, the network it ran
/// on, and — everywhere but tvOS, which has no share sheet — this row as a
/// CSV file of its own.
private struct HistoryDetailView: View {
    let entry: TestHistoryEntry
    /// Written once on appear; the share sheet hands this file over.
    @State private var exportURL: URL?

    var body: some View {
        List {
            Section("Measurements") {
                metricRow("Download", icon: "arrow.down.circle", value: SpeedFormat.text(entry.downloadMbps))
                metricRow("Upload", icon: "arrow.up.circle", value: SpeedFormat.text(entry.uploadMbps))
                metricRow("Idle Latency", icon: "timer", value: SpeedFormat.milliseconds(entry.pingMs))
                jitterRow
            }
            Section("Network") {
                LabeledContent("Connection", value: entry.connectionType.displayName)
                if let isp = entry.ispName, !isp.isEmpty {
                    LabeledContent("Network", value: isp)
                }
                LabeledContent("Date", value: entry.date.formatted(date: .long, time: .shortened))
            }
        }
        .navigationTitle("Result")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if !os(tvOS)
        .task {
            exportURL = try? writeCSVFile(named: "Edge Speed Result.csv", historyCSV([entry]))
        }
        .toolbar {
            if let exportURL {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink("Export", item: exportURL)
                }
            }
        }
        #endif
    }

    private func metricRow(_ name: String, icon: String, value: String) -> some View {
        LabeledContent {
            Text(value)
                .font(.title3.weight(.semibold))
                .monospacedDigit()
        } label: {
            Label(name, systemImage: icon)
                .foregroundStyle(.secondary)
        }
    }

    /// A single idle probe has no jitter. That's missing data, not 0 ms —
    /// the same wording the main screen uses for an unmeasured latency.
    @ViewBuilder
    private var jitterRow: some View {
        if let jitter = entry.jitterMs {
            metricRow("Jitter", icon: "waveform.path", value: SpeedFormat.milliseconds(jitter, fractionDigits: 1))
        } else {
            LabeledContent {
                Text("Not measured")
                    .foregroundStyle(.secondary)
            } label: {
                Label("Jitter", systemImage: "waveform.path")
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - CSV export

/// Writes `csv` to a temporary file and returns its URL, so `ShareLink` can
/// hand the system a real `.csv` rather than raw text.
private func writeCSVFile(named filename: String, _ csv: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(filename)
    guard let data = csv.data(using: .utf8) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: url, options: .atomic)
    return url
}

/// CSV of `entries`, oldest first so a spreadsheet reads it as a timeline.
/// Free text (ISP names like "Acme, Inc.") is escaped per RFC 4180.
private func historyCSV(_ entries: [TestHistoryEntry]) -> String {
    let formatter = ISO8601DateFormatter()
    var lines = ["date,connection,download_mbps,upload_mbps,latency_ms,jitter_ms,isp"]
    for entry in entries.reversed() {
        lines.append(
            [
                formatter.string(from: entry.date),
                entry.connectionType.displayName,
                String(entry.downloadMbps),
                String(entry.uploadMbps),
                String(entry.pingMs),
                entry.jitterMs.map { String($0) } ?? "",
                entry.ispName ?? ""
            ]
            .map(escapeCSVField)
            .joined(separator: ",")
        )
    }
    return lines.joined(separator: "\n")
}

private func escapeCSVField(_ field: String) -> String {
    guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
    return "\"\(field.replacingOccurrences(of: "\"", with: "\"\""))\""
}

#Preview {
    HistoryView()
        .modelContainer(HistoryStore.previewContainer())
}
