import Foundation

/// Thread-safe cumulative byte counter shared by concurrent download/upload workers.
actor ByteCounter {
    private(set) var total: UInt64 = 0
    private(set) var errors: UInt64 = 0

    func add(_ n: UInt64) {
        total += n
    }

    func subtract(_ n: UInt64) {
        total = total > n ? total - n : 0
    }

    func recordError() {
        errors += 1
    }

    func snapshot() -> (total: UInt64, errors: UInt64) {
        (total, errors)
    }
}

/// Per-task delegate that reports upload progress via didSendBodyData so the
/// byte counter advances incrementally instead of jumping at completion.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let counter: ByteCounter
    private var lastSent: Int64 = 0

    init(counter: ByteCounter) {
        self.counter = counter
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let delta = totalBytesSent - lastSent
        lastSent = totalBytesSent
        guard delta > 0 else { return }
        Task { await counter.add(UInt64(delta)) }
    }
}
