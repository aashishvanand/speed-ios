import Foundation
import SwiftData
import Observation
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

/// A locally persisted record of one completed speed test. Always the
/// newest schema version's model.
public typealias TestHistoryEntry = HistorySchemaV2.TestHistoryEntry

/// The history model as first shipped. Frozen: never edit a shipped schema
/// version; add a new one and a migration stage instead.
public enum HistorySchemaV1: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    public static var models: [any PersistentModel.Type] { [TestHistoryEntry.self] }

    @Model
    public final class TestHistoryEntry {
        public var date: Date
        public var downloadMbps: Double
        public var uploadMbps: Double
        public var pingMs: Double
        public var jitterMs: Double
        public var ispName: String?
        public var connectionTypeRaw: String

        public init(date: Date, downloadMbps: Double, uploadMbps: Double, pingMs: Double, jitterMs: Double, ispName: String?, connectionTypeRaw: String) {
            self.date = date
            self.downloadMbps = downloadMbps
            self.uploadMbps = uploadMbps
            self.pingMs = pingMs
            self.jitterMs = jitterMs
            self.ispName = ispName
            self.connectionTypeRaw = connectionTypeRaw
        }
    }
}

/// V2: `jitterMs` is optional, because a run with a single idle-latency
/// sample has no jitter to record.
public enum HistorySchemaV2: VersionedSchema {
    public static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    public static var models: [any PersistentModel.Type] { [TestHistoryEntry.self] }

    @Model
    public final class TestHistoryEntry {
        public var date: Date
        public var downloadMbps: Double
        public var uploadMbps: Double
        public var pingMs: Double
        /// `nil` when the run had too few latency samples to measure it.
        public var jitterMs: Double?
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
            jitterMs: Double?,
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
}

/// Every history schema version, oldest first, and how to get between them.
public enum HistoryMigrationPlan: SchemaMigrationPlan {
    public static var schemas: [any VersionedSchema.Type] { [HistorySchemaV1.self, HistorySchemaV2.self] }
    public static var stages: [MigrationStage] {
        // Making a property optional needs no custom code.
        [.lightweight(fromVersion: HistorySchemaV1.self, toVersion: HistorySchemaV2.self)]
    }
}

/// Whether history is actually being persisted, for the UI to surface.
/// Failures are logged too, but a log line is invisible to the person whose
/// results are silently not being kept.
@MainActor
@Observable
public final class HistoryHealth {
    public static let shared = HistoryHealth()

    /// The on-disk store couldn't be opened, so results last only until the
    /// app quits.
    public internal(set) var isUsingTemporaryStore = false
    /// The on-disk store couldn't be opened, so it was moved aside and a
    /// fresh, empty one created in its place.
    public internal(set) var didResetUnreadableStore = false
    /// The most recent failed save/prune/delete, cleared by the next success.
    public internal(set) var lastError: String?

    init() {}
}

/// Owns history persistence: a local store with no sync of its own (CloudKit
/// is explicitly disabled, so it stays that way even if an iCloud entitlement
/// is added later — though like any app data in Application Support it is
/// included in the user's device and iCloud backups), a retention cap, and
/// failures that are logged and surfaced through `HistoryHealth` rather than
/// swallowed.
public enum HistoryStore {
    /// Newest entries kept; older ones are pruned on each insert.
    public static let retentionLimit = 200

    static let logger = Logger(subsystem: "me.aashishvanand.speed", category: "history")

    /// The schema every container opens with: always the newest version.
    static var schema: Schema { Schema(versionedSchema: HistorySchemaV2.self) }

    /// The app's shared container.
    ///
    /// If the on-disk store can't be opened, its files are moved aside (not
    /// deleted) and a fresh store is created, so one bad file doesn't cost
    /// history on every launch until the app is reinstalled. Only if that
    /// fails too does it fall back to an in-memory store, so a broken store
    /// costs history rather than crashing the app.
    @MainActor
    public static let container: ModelContainer = {
        let url = ModelConfiguration(cloudKitDatabase: .none).url
        if let container = openRecovering(at: url) { return container }
        HistoryHealth.shared.isUsingTemporaryStore = true
        return previewContainer()
    }()

    /// Opens (migrating if needed) the store at `url`.
    static func open(at url: URL) throws -> ModelContainer {
        try ModelContainer(
            for: schema,
            migrationPlan: HistoryMigrationPlan.self,
            configurations: ModelConfiguration(schema: schema, url: url, cloudKitDatabase: .none)
        )
    }

    /// Opens the store at `url`. If that fails, moves its files aside and
    /// tries once more with an empty store. Nil if both attempts fail.
    @MainActor
    static func openRecovering(at url: URL) -> ModelContainer? {
        do {
            return try open(at: url)
        } catch {
            logger.error("Opening history store failed, moving it aside: \(error.localizedDescription, privacy: .public)")
        }
        moveAside(storeAt: url)
        do {
            let container = try open(at: url)
            HistoryHealth.shared.didResetUnreadableStore = true
            return container
        } catch {
            logger.error("Recreating history store failed, using in-memory store: \(error.localizedDescription, privacy: .public)")
            return nil
        }
    }

    /// Renames the store and its SQLite sidecar files to `<name>.unreadable`,
    /// replacing any earlier copy, so a later look at the data is possible
    /// without it piling up.
    static func moveAside(storeAt url: URL) {
        let fileManager = FileManager.default
        for suffix in ["", "-shm", "-wal"] {
            let file = URL(fileURLWithPath: url.path + suffix)
            guard fileManager.fileExists(atPath: file.path) else { continue }
            let backup = URL(fileURLWithPath: file.path + ".unreadable")
            try? fileManager.removeItem(at: backup)
            do {
                try fileManager.moveItem(at: file, to: backup)
            } catch {
                logger.error("Moving \(file.lastPathComponent, privacy: .public) aside failed: \(error.localizedDescription, privacy: .public)")
                try? fileManager.removeItem(at: file)
            }
        }
    }

    /// Throwaway in-memory container for previews and the fallback path.
    @MainActor
    public static func previewContainer() -> ModelContainer {
        // An in-memory store with no CloudKit can't fail to open.
        try! ModelContainer(
            for: schema,
            configurations: ModelConfiguration(schema: schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        )
    }

    /// Inserts `entry`, prunes everything beyond `retentionLimit`, and saves.
    @MainActor
    public static func record(_ entry: TestHistoryEntry, in context: ModelContext) {
        context.insert(entry)
        // Save the insert before pruning. A fetch with `fetchOffset` applies
        // the offset in the store only, then appends unsaved inserts that
        // match. So the brand-new entry always lands in "overflow" and gets
        // deleted. Fetching saved rows only avoids that.
        save(context)
        var overflow = FetchDescriptor<TestHistoryEntry>(sortBy: [SortDescriptor(\.date, order: .reverse)])
        overflow.fetchOffset = retentionLimit
        overflow.includePendingChanges = false
        do {
            for stale in try context.fetch(overflow) {
                context.delete(stale)
            }
        } catch {
            logger.error("Pruning history failed: \(error.localizedDescription, privacy: .public)")
            HistoryHealth.shared.lastError = error.localizedDescription
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
            HistoryHealth.shared.lastError = error.localizedDescription
            return
        }
        save(context)
    }

    @MainActor
    static func save(_ context: ModelContext) {
        do {
            try context.save()
            HistoryHealth.shared.lastError = nil
        } catch {
            logger.error("Saving history failed: \(error.localizedDescription, privacy: .public)")
            HistoryHealth.shared.lastError = error.localizedDescription
        }
    }
}
