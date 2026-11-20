import Foundation
import os

/// Thread-safe cumulative byte counter shared by concurrent download/upload
/// workers.
///
/// Lock-backed rather than an actor on purpose: it's incremented from
/// URLSession delegate callbacks for every received chunk / upload progress
/// event. An actor would need a `Task { await counter.add(n) }` per callback —
/// thousands of task allocations and executor hops per second per worker,
/// competing with the sampling clock on the cooperative pool, and leaving
/// each snapshot lagging the wire by however many hops were still queued.
/// An uncontended unfair lock is a few nanoseconds and is exact.
final class ByteCounter: Sendable {
    private struct State {
        var total: UInt64 = 0
        var errors: UInt64 = 0
        var lastRejectedStatus: Int?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func add(_ n: UInt64) {
        state.withLock { $0.total &+= n }
    }

    /// Takes back bytes already counted for a request the server rejected.
    func subtract(_ n: UInt64) {
        state.withLock { $0.total = $0.total >= n ? $0.total - n : 0 }
    }

    func recordError() {
        state.withLock { $0.errors += 1 }
    }

    /// A request the server answered with a non-2xx status.
    func recordRejection(status: Int) {
        state.withLock {
            $0.errors += 1
            $0.lastRejectedStatus = status
        }
    }

    func snapshot() -> (total: UInt64, errors: UInt64) {
        state.withLock { ($0.total, $0.errors) }
    }

    var lastRejectedStatus: Int? {
        state.withLock { $0.lastRejectedStatus }
    }
}

/// One-shot flag: exactly one of several racing callers wins `claim()`.
final class OneShot: Sendable {
    private let claimed = OSAllocatedUnfairLock(initialState: false)

    func claim() -> Bool {
        claimed.withLock { claimed in
            guard !claimed else { return false }
            claimed = true
            return true
        }
    }
}

/// A non-2xx HTTP status. Thrown by latency probes, and reported (not thrown)
/// by transfers so the worker can count the rejection.
struct HTTPStatusError: Error, Equatable {
    let statusCode: Int
}

extension HTTPURLResponse {
    var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// How one transfer ended.
struct TransferOutcome: Sendable {
    /// The response, if headers arrived.
    var response: HTTPURLResponse?
    /// Upload body bytes this request added to the counter.
    var bytesSent: UInt64
    /// Download body bytes this request added to the counter.
    var bytesReceived: UInt64 = 0

    var rejectedStatus: Int? {
        guard let response, !response.isSuccess else { return nil }
        return response.statusCode
    }
}

/// Per-task delegate for both directions of a throughput transfer.
///
/// - Download: body bytes stream into the counter and are discarded at once,
///   never buffered.
/// - Upload: send progress streams into the counter; the (tiny) response body
///   is discarded, with a size cap so a misbehaving server can't make us
///   buffer or read without bound.
///
/// Either way the status code is checked as soon as headers arrive: a non-2xx
/// response is cancelled before any of its body is counted, so error pages
/// never inflate a measurement.
///
/// Downloads use a raw data task rather than `URLSession.bytes(for:)` because
/// `AsyncBytes` vends a single *byte* per `await`: at line rate that is millions
/// of async resumptions per second, per worker. With several workers running
/// concurrently that pins every thread in the cooperative pool, so the sampling
/// tick that drives the live graph never gets scheduled and the phase overruns
/// its duration by an order of magnitude.
final class TransferDelegate: NSObject, URLSessionDataDelegate, Sendable {
    enum Direction: Sendable {
        case download
        /// `bodyLength` is the full upload size, used to credit bytes a 2xx
        /// response proves were delivered but that progress didn't report.
        case upload(bodyLength: UInt64)
    }

    /// Cap on a response body we read only to throw away (upload replies).
    static let maxDiscardedResponseBytes = 64 * 1024

    private struct State {
        var continuation: CheckedContinuation<TransferOutcome, Error>?
        var response: HTTPURLResponse?
        var lastReportedSent: Int64 = 0
        var bytesSent: UInt64 = 0
        var bytesReceived: UInt64 = 0
        var discarded = 0
        var rejected = false
        var finished = false
    }

    private let direction: Direction
    private let counter: ByteCounter
    private let onResponse: @Sendable (URLResponse) -> Void
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    init(direction: Direction, counter: ByteCounter, onResponse: @escaping @Sendable (URLResponse) -> Void = { _ in }) {
        self.direction = direction
        self.counter = counter
        self.onResponse = onResponse
    }

    /// Hands the delegate the continuation to resume once the task completes.
    /// Called before `resume()`, so it always runs ahead of any callback.
    func attach(_ continuation: CheckedContinuation<TransferOutcome, Error>) {
        state.withLockUnchecked { $0.continuation = continuation }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        let http = response as? HTTPURLResponse
        let ok = http?.isSuccess ?? false
        state.withLockUnchecked {
            $0.response = http
            $0.rejected = !ok
        }
        onResponse(response)
        // Don't read an error page's body at all.
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard !data.isEmpty else { return }
        switch direction {
        case .download:
            counter.add(UInt64(data.count))
            state.withLockUnchecked { $0.bytesReceived += UInt64(data.count) }
        case .upload:
            let overLimit = state.withLockUnchecked { state -> Bool in
                state.discarded += data.count
                return state.discarded > Self.maxDiscardedResponseBytes
            }
            if overLimit { dataTask.cancel() }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let delta = state.withLockUnchecked { state -> Int64 in
            let delta = totalBytesSent - state.lastReportedSent
            guard delta > 0 else { return 0 }
            state.lastReportedSent = totalBytesSent
            state.bytesSent += UInt64(delta)
            return delta
        }
        guard delta > 0 else { return }
        counter.add(UInt64(delta))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, outcome, rejected) = state.withLockUnchecked { state -> (CheckedContinuation<TransferOutcome, Error>?, TransferOutcome, Bool) in
            guard !state.finished else { return (nil, TransferOutcome(bytesSent: 0), false) }
            state.finished = true
            // A 2xx reply to a POST means the server took the whole body;
            // credit whatever progress callbacks didn't report.
            if error == nil, case .upload(let bodyLength) = direction, state.response?.isSuccess == true, state.bytesSent < bodyLength {
                let missing = bodyLength - state.bytesSent
                state.bytesSent = bodyLength
                counter.add(missing)
            }
            defer { state.continuation = nil }
            return (state.continuation, TransferOutcome(response: state.response, bytesSent: state.bytesSent, bytesReceived: state.bytesReceived), state.rejected)
        }
        // Our own `.cancel` of a rejected response surfaces as a cancellation
        // error; report the status instead so the worker can count it.
        if let error, !rejected {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: outcome)
        }
    }
}

/// Runs a single transfer task to completion through a `TransferDelegate`.
/// Honours task cancellation by cancelling the underlying transfer
/// mid-stream, so a phase ends on its clock even when one body would take far
/// longer than the phase.
func runTransfer(_ task: URLSessionTask, delegate: TransferDelegate) async throws -> TransferOutcome {
    task.delegate = delegate
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            delegate.attach(continuation)
            task.resume()
        }
    } onCancel: {
        task.cancel()
    }
}
