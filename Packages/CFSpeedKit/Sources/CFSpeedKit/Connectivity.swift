import Foundation
import Network
import Observation
import os

extension ConnectionType {
    init(path: NWPath) {
        if path.usesInterfaceType(.wifi) {
            self = .wifi
        } else if path.usesInterfaceType(.cellular) {
            self = .cellular
        } else if path.usesInterfaceType(.wiredEthernet) {
            self = .wiredEthernet
        } else if path.status == .satisfied {
            self = .other
        } else {
            self = .unknown
        }
    }
}

/// Bridges `NWPathMonitor`'s callback API to an `AsyncStream`. The monitor
/// invokes its handler once with the current path immediately after starting,
/// so the first element is available right away rather than only on the next
/// change — which is what makes a one-shot `first` lookup cheap.
func networkPaths() -> AsyncStream<NWPath> {
    AsyncStream { continuation in
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { continuation.yield($0) }
        continuation.onTermination = { _ in monitor.cancel() }
        monitor.start(queue: DispatchQueue(label: "cfspeedkit.pathmonitor"))
    }
}

/// Live view of the interface currently carrying traffic, and whether the OS
/// believes there's a usable path at all.
///
/// This is a UI affordance, not a gate on requests. A satisfied path doesn't
/// mean a given host answers (captive portals and DNS blackholes both look
/// satisfied), and any check is racy against the request that follows it.
/// `SpeedTestRunner` therefore decides from the `URLError` its first real
/// request fails with. What this is good for is tagging history entries with
/// the interface, noticing the moment connectivity returns so a failed run
/// can retry itself, and keeping *automatic* runs off metered links.
@MainActor
@Observable
public final class ConnectivityMonitor {
    public private(set) var isOnline = true
    public private(set) var connectionType: ConnectionType = .unknown
    /// Cellular or a personal hotspot — the OS's "this costs money" flag.
    public private(set) var isExpensive = false
    /// Low Data Mode is on for this interface.
    public private(set) var isConstrained = false
    /// False until the first path update lands. Until then the flags above
    /// are placeholders, so nothing should act on them.
    public private(set) var hasResolvedPath = false

    /// A full test can move hundreds of MB, so it only starts on its own over
    /// an unmetered, unconstrained path. A manual tap is never restricted.
    public var allowsAutomaticTest: Bool {
        hasResolvedPath && isOnline && !isExpensive && !isConstrained
    }

    private let watcher = CancelOnDeinit()

    public init() {
        watcher.task = Task { [weak self] in
            for await path in networkPaths() {
                guard let self else { return }
                self.isOnline = path.status == .satisfied
                self.connectionType = ConnectionType(path: path)
                self.isExpensive = path.isExpensive
                self.isConstrained = path.isConstrained
                self.hasResolvedPath = true
            }
        }
    }
}

/// Cancels the task it holds when it's deallocated. Lets a `@MainActor`
/// owner tear its background task down without touching isolated state from
/// its nonisolated `deinit`.
final class CancelOnDeinit: Sendable {
    private let stored = OSAllocatedUnfairLock<Task<Void, Never>?>(initialState: nil)

    var task: Task<Void, Never>? {
        get { stored.withLock { $0 } }
        set { stored.withLock { $0 = newValue } }
    }

    deinit {
        stored.withLock { $0?.cancel() }
    }
}
