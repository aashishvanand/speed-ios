import Foundation
import Network

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

/// Live view of whether the OS believes this device has a usable network
/// path, so the UI can show an offline state instead of auto-starting a run
/// that can only produce zeros.
///
/// A satisfied path is necessary but not sufficient: captive portals, DNS
/// blackholes and blocked endpoints all present as satisfied. The runner
/// therefore treats "not one latency probe came back" as the authoritative
/// offline signal — see `SpeedTestRunner.run()`.
@MainActor
public final class ConnectivityMonitor: ObservableObject {
    @Published public private(set) var isOnline = true
    @Published public private(set) var connectionType: ConnectionType = .unknown

    private var watchTask: Task<Void, Never>?

    public init() {
        watchTask = Task { [weak self] in
            for await path in networkPaths() {
                guard let self else { return }
                self.isOnline = path.status == .satisfied
                self.connectionType = ConnectionType(path: path)
            }
        }
    }

    deinit {
        watchTask?.cancel()
    }

    /// One-shot read of the current path status, for callers that only need
    /// to gate a single action rather than observe over time.
    public static func isOnlineNow() async -> Bool {
        for await path in networkPaths() {
            return path.status == .satisfied
        }
        return false
    }
}
