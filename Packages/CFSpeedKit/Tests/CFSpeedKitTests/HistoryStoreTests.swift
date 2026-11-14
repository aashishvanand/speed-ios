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
}
