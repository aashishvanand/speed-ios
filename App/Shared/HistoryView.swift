import SwiftUI
import SwiftData
import CFSpeedKit

struct HistoryView: View {
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \TestHistoryEntry.date, order: .reverse) private var entries: [TestHistoryEntry]

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
                    }
                }
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
                        Button("Clear All", role: .destructive) { clearAll() }
                    }
                }
            }
        }
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

            HStack(spacing: 18) {
                metric(icon: "arrow.down.circle", value: entry.downloadMbps, unit: "Mbps")
                metric(icon: "arrow.up.circle", value: entry.uploadMbps, unit: "Mbps")
                metric(icon: "timer", value: entry.pingMs, unit: "ms")
            }

            if let isp = entry.ispName, !isp.isEmpty {
                Text(isp)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func metric(icon: String, value: Double, unit: String) -> some View {
        Label(String(format: "%.0f %@", value, unit), systemImage: icon)
            .font(.subheadline.weight(.medium))
            .monospacedDigit()
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
