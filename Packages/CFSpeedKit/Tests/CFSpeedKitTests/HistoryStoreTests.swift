import Foundation
import SwiftData
import Testing
@testable import CFSpeedKit

@MainActor
struct HistoryStoreTests {
    private func entry(_ offset: TimeInterval) -> TestHistoryEntry {
        TestHistoryEntry(
            date: Date(timeIntervalSince1970: 1_000_000 + offset),
            downloadMbps: 100, uploadMbps: 50, pingMs: 10, jitterMs: 1,
            ispName: "Test ISP", connectionType: .wifi
        )
    }

    private func count(_ context: ModelContext) throws -> Int {
        try context.fetchCount(FetchDescriptor<TestHistoryEntry>())
    }

    @Test func recordKeepsTheFirstEntry() throws {
        let container = HistoryStore.previewContainer()
        let context = container.mainContext
        HistoryStore.record(entry(0), in: context)
        #expect(try count(context) == 1)
        // A fresh context sees only what was actually saved.
        #expect(try count(ModelContext(container)) == 1)
    }

    @Test func recordKeepsEveryEntryBelowTheLimit() throws {
        let container = HistoryStore.previewContainer()
        let context = container.mainContext
        for i in 0..<5 { HistoryStore.record(entry(Double(i)), in: context) }
        #expect(try count(ModelContext(container)) == 5)
    }

    @Test func recordPrunesOldestBeyondTheLimit() throws {
        let container = HistoryStore.previewContainer()
        let context = container.mainContext
        let total = HistoryStore.retentionLimit + 3
        for i in 0..<total { HistoryStore.record(entry(Double(i)), in: context) }
        let fresh = ModelContext(container)
        #expect(try count(fresh) == HistoryStore.retentionLimit)
        var oldest = FetchDescriptor<TestHistoryEntry>(sortBy: [SortDescriptor(\.date)])
        oldest.fetchLimit = 1
        let first = try #require(try fresh.fetch(oldest).first)
        #expect(first.date == Date(timeIntervalSince1970: 1_000_000 + 3))
    }

    private func temporaryStoreURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appending(path: "HistoryStoreTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appending(path: "history.store")
    }

    @Test func migratesAVersionOneStore() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        do {
            let v1 = Schema(versionedSchema: HistorySchemaV1.self)
            let container = try ModelContainer(for: v1, configurations: ModelConfiguration(schema: v1, url: url, cloudKitDatabase: .none))
            let context = ModelContext(container)
            context.insert(HistorySchemaV1.TestHistoryEntry(
                date: Date(timeIntervalSince1970: 1_000_000), downloadMbps: 100, uploadMbps: 50,
                pingMs: 10, jitterMs: 1.5, ispName: "Old ISP", connectionTypeRaw: "wifi"
            ))
            try context.save()
        }
        let container = try HistoryStore.open(at: url)
        let entries = try ModelContext(container).fetch(FetchDescriptor<TestHistoryEntry>())
        #expect(entries.count == 1)
        #expect(entries.first?.jitterMs == 1.5)
        #expect(entries.first?.connectionType == .wifi)
    }

    @Test func storesMissingJitter() throws {
        let container = HistoryStore.previewContainer()
        let context = container.mainContext
        HistoryStore.record(TestHistoryEntry(downloadMbps: 1, uploadMbps: 1, pingMs: 1, jitterMs: nil, ispName: nil, connectionType: .wifi), in: context)
        let saved = try ModelContext(container).fetch(FetchDescriptor<TestHistoryEntry>())
        #expect(saved.first?.jitterMs == nil)
    }

    @Test func replacesAnUnreadableStore() throws {
        let url = try temporaryStoreURL()
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        try Data("not a database".utf8).write(to: url)

        let container = try #require(HistoryStore.openRecovering(at: url))
        #expect(HistoryHealth.shared.didResetUnreadableStore)
        // The bad file is kept beside the new store, not deleted.
        #expect(FileManager.default.fileExists(atPath: url.path + ".unreadable"))
        // And the new store works.
        HistoryStore.record(entry(0), in: container.mainContext)
        #expect(try count(ModelContext(container)) == 1)
    }
}
