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
    }

    private let state = OSAllocatedUnfairLock(initialState: State())

    func add(_ n: UInt64) {
        state.withLock { $0.total &+= n }
    }

    func recordError() {
        state.withLock { $0.errors += 1 }
    }

    func snapshot() -> (total: UInt64, errors: UInt64) {
        state.withLock { ($0.total, $0.errors) }
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

/// Per-task delegate that reports upload progress via didSendBodyData so the
/// byte counter advances incrementally instead of jumping at completion.
final class UploadProgressDelegate: NSObject, URLSessionTaskDelegate, Sendable {
    private let counter: ByteCounter
    private let lastSent = OSAllocatedUnfairLock<Int64>(initialState: 0)

    init(counter: ByteCounter) {
        self.counter = counter
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        let delta = lastSent.withLock { last in
            defer { last = totalBytesSent }
            return totalBytesSent - last
        }
        guard delta > 0 else { return }
        counter.add(UInt64(delta))
    }
}

/// Per-task delegate that streams a download's body into the byte counter and
/// immediately discards it.
///
/// Downloads use a raw data task rather than `URLSession.bytes(for:)` because
/// `AsyncBytes` vends a single *byte* per `await`: at line rate that is millions
/// of async resumptions per second, per worker. With several workers running
/// concurrently that pins every thread in the cooperative pool, so the sampling
/// tick that drives the live graph never gets scheduled and the phase overruns
/// its duration by an order of magnitude.
final class DownloadProgressDelegate: NSObject, URLSessionDataDelegate, Sendable {
    private struct State {
        var continuation: CheckedContinuation<URLResponse?, Error>?
        var response: URLResponse?
        var finished = false
    }

    private let counter: ByteCounter
    private let onResponse: @Sendable (URLResponse) -> Void
    private let state = OSAllocatedUnfairLock<State>(uncheckedState: State())

    init(counter: ByteCounter, onResponse: @escaping @Sendable (URLResponse) -> Void) {
        self.counter = counter
        self.onResponse = onResponse
    }

    /// Hands the delegate the continuation to resume once the body completes.
    /// Called before `resume()`, so it always runs ahead of any callback.
    func attach(_ continuation: CheckedContinuation<URLResponse?, Error>) {
        state.withLockUnchecked { $0.continuation = continuation }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse, completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
        state.withLockUnchecked { $0.response = response }
        onResponse(response)
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let count = UInt64(data.count)
        guard count > 0 else { return }
        counter.add(count)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (continuation, response): (CheckedContinuation<URLResponse?, Error>?, URLResponse?) = state.withLockUnchecked { state in
            guard !state.finished else { return (nil, nil) }
            state.finished = true
            defer { state.continuation = nil }
            return (state.continuation, state.response)
        }
        if let error {
            continuation?.resume(throwing: error)
        } else {
            continuation?.resume(returning: response ?? task.response)
        }
    }
}

/// Runs a single download to completion, feeding its bytes into `counter` as
/// they arrive and discarding them. Returns the response (headers only — the
/// body is never buffered). Honours task cancellation by cancelling the
/// underlying transfer mid-stream.
@discardableResult
func streamDownload(
    session: URLSession,
    request: URLRequest,
    counter: ByteCounter,
    onResponse: @escaping @Sendable (URLResponse) -> Void
) async throws -> URLResponse? {
    let delegate = DownloadProgressDelegate(counter: counter, onResponse: onResponse)
    let task = session.dataTask(with: request)
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
