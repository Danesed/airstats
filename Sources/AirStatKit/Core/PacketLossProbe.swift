import Foundation

/// How the probe measures loss. The shipping implementation is one `/sbin/ping`
/// run answering the fraction of ten echo requests that never came back; tests
/// substitute a closure so the throttle and the enable gate run offline.
public typealias LossTransport =
    @Sendable (@escaping @Sendable (MetricState<Double>) -> Void) -> Void

/// Fraction of ICMP echo requests lost, probed only while the panel is open.
///
/// A sibling of `LatencyProbe` with the same rules because it answers a sibling
/// question: the reading belongs to a moment, is fetched off the sampling queue,
/// and is cached under a lock so `collect()` pays a lock and nothing else.
/// `setEnabled` follows panel visibility — a closed panel means no pings at all.
///
/// The transport is a short `/sbin/ping` run rather than an ICMP socket of our
/// own: ten echo requests answer "is this link dropping packets" as honestly as
/// four hundred lines of checksum code, and the subprocess is one spawn every
/// thirty seconds while someone is looking.
public final class PacketLossProbe: @unchecked Sendable {

    /// Thirty seconds. Loss is a slow-moving property of the link — a burst every
    /// half minute tracks it; faster would only feed the meter it reads.
    public static let refreshInterval: TimeInterval = 30

    /// Same endpoint the latency probe times: if one machine answers both, the
    /// loss reading and the latency reading describe the same path.
    public static let target = "captive.apple.com"

    /// Ten requests, four a second, inside an eight-second ceiling. A wider window
    /// would measure loss more precisely; ten is enough to tell clean from flaky,
    /// which is the only question the row answers.
    public static let pingArguments = ["-c", "10", "-i", "0.25", "-t", "8", "-n", "-q"]

    private let transport: LossTransport
    private let lock = NSLock()
    private var isEnabled = false
    private var state: MetricState<Double> = .failure(.unsupported("panel is closed"))
    private var lastAttempt: ContinuousClock.Instant?
    private var isFetching = false
    /// Bumped on every toggle, so a reply that lands after the panel closed is
    /// discarded rather than displayed next time it opens.
    private var generation: UInt64 = 0

    public init(transport: @escaping LossTransport = PacketLossProbe.pingTransport()) {
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

    public func currentState() -> MetricState<Double> {
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

    private func finish(_ result: MetricState<Double>, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, isEnabled else { return }
        isFetching = false
        state = result
    }

    // MARK: Transport

    /// `/sbin/ping -q -n -c 10 -i 0.25 -t 8`: the summary run, quiet flag so only
    /// the "N packets transmitted, M received" line needs parsing.
    public static func pingTransport(target: String = PacketLossProbe.target) -> LossTransport {
        { completion in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/sbin/ping")
            process.arguments = pingArguments + [target]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = Pipe()
            process.terminationHandler = { process in
                let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(),
                                  as: UTF8.self)
                if process.terminationStatus == 0 || process.terminationStatus == 2 {
                    // ping exits 2 when every request was lost: still an answer.
                    completion(interpret(text))
                } else {
                    completion(.failure(.failed("ping exited \(process.terminationStatus)")))
                }
            }
            do {
                try process.run()
            } catch {
                completion(.failure(.failed("ping could not start")))
            }
        }
    }

    /// "10 packets transmitted, 10 received, 0.0% packet loss" → 0.0. The one
    /// summary line that exists in every ping variant shipped by macOS.
    static func interpret(_ output: String) -> MetricState<Double> {
        guard let match = output.range(of: #"(\d+(?:\.\d+)?)%\s+packet\s+loss"#,
                                       options: .regularExpression),
              let percent = Double(output[match].dropLast("% packet loss".count)) else {
            return .failure(.failed("no loss figure in the summary"))
        }
        return .value(percent / 100)
    }
}
