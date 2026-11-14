import SwiftUI
import SwiftData
import CFSpeedKit

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TestHistoryEntry.date, order: .reverse) private var entries: [TestHistoryEntry]
    @State private var confirmingClearAll = false
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
                                row(entry)
                                    #if !os(tvOS)
                                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                        Button(role: .destructive) {
                                            delete(entry)
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                    }
                                    #endif
                            }
                            #if os(tvOS)
                            .onDelete(perform: deleteOffsets)
                            #endif
                        } footer: {
                            Text("Only your latest \(HistoryStore.retentionLimit) results are kept. Older ones are removed automatically.")
                        }
                    }
                }
            }
            .safeAreaInset(edge: .top, spacing: 0) {
                healthBanner
            }
            .navigationTitle("History")
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
        }
    }

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
        if let error = health.lastError {
            return "Couldn't save history: \(error)"
        }
        return nil
    }

    private func row(_ entry: TestHistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Label(entry.connectionType.displayName, systemImage: connectionIcon(entry.connectionType))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(entry.date, format: .dateTime.month().day().year().hour().minute())
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            // Side by side when they fit, stacked at large text sizes.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 18) { metrics(entry) }
                VStack(alignment: .leading, spacing: 4) { metrics(entry) }
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
    private func metrics(_ entry: TestHistoryEntry) -> some View {
        metric(icon: "arrow.down.circle", name: "Download", value: SpeedFormat.text(entry.downloadMbps))
        metric(icon: "arrow.up.circle", name: "Upload", value: SpeedFormat.text(entry.uploadMbps))
        metric(icon: "timer", name: "Latency", value: String(format: "%.0f ms", entry.pingMs))
    }

    private func metric(icon: String, name: String, value: String) -> some View {
        Label(value, systemImage: icon)
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
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

    #if os(tvOS)
    private func deleteOffsets(_ offsets: IndexSet) {
        HistoryStore.delete(offsets.map { entries[$0] }, in: modelContext)
    }
    #endif

    private func clearAll() {
        HistoryStore.deleteAll(in: modelContext)
    }
}

#Preview {
    HistoryView()
        .modelContainer(HistoryStore.previewContainer())
}
