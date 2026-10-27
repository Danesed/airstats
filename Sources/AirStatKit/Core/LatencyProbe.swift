import Foundation

/// How the probe reaches the network. The shipping implementation is one timed
/// URLSession round trip answering the seconds it took; tests substitute a closure
/// so the throttle and the enable gate can be exercised offline.
public typealias LatencyTransport =
    @Sendable (@escaping @Sendable (MetricState<TimeInterval>) -> Void) -> Void

/// Round-trip time to a fixed endpoint, probed only while the panel is open.
///
/// Follows `PublicIPFetcher`'s rules because it answers the same kind of question:
/// a reading that belongs to a moment, fetched off the sampling queue and cached
/// under a lock so `collect()` pays a lock and nothing else.
///
/// The probe exists for the panel's network module, so `setEnabled` follows panel
/// visibility: a closed panel means no requests at all, and re-opening starts over
/// pending rather than on a stale answer.
public final class LatencyProbe: @unchecked Sendable {

    /// Four seconds. A latency reading is only interesting while it is fresh, but
    /// the probe exists to answer "is the link slow right now", not to benchmark it:
    /// fifteen requests a minute while the panel is open is enough that congestion
    /// shows and few enough that it cannot add to it.
    public static let refreshInterval: TimeInterval = 4

    /// Apple's captive-portal probe, the endpoint macOS itself asks "is the
    /// internet reachable" of. HTTPS keeps it inside App Transport Security, and
    /// the reply is a handful of bytes — the lightest honest RTT available, to a
    /// service this machine already talks to on its own.
    public static let endpoint = URL(string: "https://captive.apple.com/hotspot-detect.html")!

    private let transport: LatencyTransport
    private let lock = NSLock()
    private var isEnabled = false
    private var state: MetricState<TimeInterval> = .failure(.unsupported("panel is closed"))
    private var lastAttempt: ContinuousClock.Instant?
    private var isFetching = false
    /// Bumped on every toggle, so a reply that lands after the panel closed is
    /// discarded rather than displayed next time it opens.
    private var generation: UInt64 = 0

    public init(transport: @escaping LatencyTransport = LatencyProbe.httpTransport()) {
        self.transport = transport
    }

    public func setEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard enabled != isEnabled else { return }
        isEnabled = enabled
        generation &+= 1
        lastAttempt = nil
        isFetching = false
        state = enabled ? .pending : .failure(.unsupported("panel is closed"))
    }

    public func currentState() -> MetricState<TimeInterval> {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    /// Starts a probe if the panel is open and the last one is old enough. Returns
    /// without waiting, so the caller may be the sampling queue.
    public func refreshIfDue() {
        lock.lock()
        guard isEnabled, !isFetching,
              lastAttempt.map({ Monotonic.seconds(since: $0) >= Self.refreshInterval }) ?? true
        else {
            lock.unlock()
            return
        }
        isFetching = true
        lastAttempt = Monotonic.now
        let generation = self.generation
        lock.unlock()

        transport { [weak self] result in
            self?.finish(result, generation: generation)
        }
    }

    /// Triggers an immediate probe on demand, resetting the throttle timer.
    public func triggerProbe() {
        lock.lock()
        guard isEnabled, !isFetching else {
            lock.unlock()
            return
        }
        isFetching = true
        lastAttempt = Monotonic.now
        let generation = self.generation
        state = .pending
        lock.unlock()

        transport { [weak self] result in
            self?.finish(result, generation: generation)
        }
    }

    private func finish(_ result: MetricState<TimeInterval>, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, isEnabled else { return }
        isFetching = false
        state = result
    }

    // MARK: Transport

    /// One ephemeral GET, timed start to finish: connect, TLS and first byte are
    /// the latency a user feels, so the whole round trip is the measurement.
    public static func httpTransport(endpoint: URL = LatencyProbe.endpoint) -> LatencyTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 8
        let session = URLSession(configuration: configuration)

        return { completion in
            var request = URLRequest(url: endpoint)
            request.httpMethod = "GET"
            request.setValue("AirStats", forHTTPHeaderField: "User-Agent")
            let start = ContinuousClock.now
            session.dataTask(with: request) { _, response, error in
                let elapsed = ContinuousClock.now - start
                let seconds = Double(elapsed.components.seconds)
                    + Double(elapsed.components.attoseconds) / 1e18
                if let error {
                    completion(.failure(.failed("unreachable: \(error.localizedDescription)")))
                } else if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    completion(.failure(.failed("endpoint answered HTTP \(http.statusCode)")))
                } else {
                    completion(.value(seconds))
                }
            }.resume()
        }
    }
}
