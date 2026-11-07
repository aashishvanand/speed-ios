import Foundation
import SwiftData
import os

/// The network interface a completed test ran over, for display in history.
///
/// Raw values are stable storage codes, never shown to users — renaming a
/// label must not orphan rows already on disk. Use `displayName` for UI.
public enum ConnectionType: String, Codable, Sendable {
    case wifi
    case cellular
    case wiredEthernet = "ethernet"
    case other
    case unknown

    public var displayName: String {
        switch self {
        case .wifi: return "Wi-Fi"
        case .cellular: return "Cellular"
        case .wiredEthernet: return "Ethernet"
        case .other: return "Other"
        case .unknown: return "Unknown"
        }
    }
}

/// A locally persisted record of one completed speed test.
@Model
public final class TestHistoryEntry {
    public var date: Date
    public var downloadMbps: Double
    public var uploadMbps: Double
    public var pingMs: Double
    public var jitterMs: Double
    public var ispName: String?
    public var connectionTypeRaw: String

    public var connectionType: ConnectionType {
        ConnectionType(rawValue: connectionTypeRaw) ?? .unknown
    }

    public init(
        date: Date = .now,
        downloadMbps: Double,
        uploadMbps: Double,
        pingMs: Double,
        jitterMs: Double,
        ispName: String?,
        connectionType: ConnectionType
    ) {
        self.date = date
        self.downloadMbps = downloadMbps
        self.uploadMbps = uploadMbps
        self.pingMs = pingMs
        self.jitterMs = jitterMs
        self.ispName = ispName
        self.connectionTypeRaw = connectionType.rawValue
    }
}

/// Owns history persistence: a strictly local store (CloudKit sync is
/// explicitly disabled, so history never leaves the device even if an iCloud
/// entitlement is added later), a retention cap, and logged — not
/// swallowed — save failures.
public enum HistoryStore {
    /// Newest entries kept; older ones are pruned on each insert.
    public static let retentionLimit = 200

    static let logger = Logger(subsystem: "me.aashishvanand.speed", category: "history")

    /// The app's shared container. Falls back to an in-memory store if the
    /// on-disk one can't be opened, so a corrupt store costs history rather
    /// than crashing the app.
    @MainActor
    public static let container: ModelContainer = {
        do {
            return try ModelContainer(
                for: TestHistoryEntry.self,
                configurations: ModelConfiguration(cloudKitDatabase: .none)
            )
        } catch {
            logger.error("Opening history store failed, using in-memory store: \(error.localizedDescription, privacy: .public)")
            return previewContainer()
        }
    }()

    /// Throwaway in-memory container for previews and the fallback path.
    @MainActor
    public static func previewContainer() -> ModelContainer {
        // An in-memory store with no CloudKit can't fail to open.
        try! ModelContainer(
            for: TestHistoryEntry.self,
            configurations: ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    /// Inserts `entry`, prunes everything beyond `retentionLimit`, and saves.
    @MainActor
    public static func record(_ entry: TestHistoryEntry, in context: ModelContext) {
        context.insert(entry)
        var overflow = FetchDescriptor<TestHistoryEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        overflow.fetchOffset = retentionLimit
        do {
            for stale in try context.fetch(overflow) {
                context.delete(stale)
            }
        } catch {
            logger.error("Pruning history failed: \(error.localizedDescription, privacy: .public)")
        }
        save(context)
    }

    @MainActor
    public static func delete(_ entries: [TestHistoryEntry], in context: ModelContext) {
        for entry in entries { context.delete(entry) }
        save(context)
    }

    @MainActor
    public static func deleteAll(in context: ModelContext) {
        do {
            try context.delete(model: TestHistoryEntry.self)
        } catch {
            logger.error("Clearing history failed: \(error.localizedDescription, privacy: .public)")
        }
        save(context)
    }

    @MainActor
    static func save(_ context: ModelContext) {
        do {
            try context.save()
        } catch {
            logger.error("Saving history failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
