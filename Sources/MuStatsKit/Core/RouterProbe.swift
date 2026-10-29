import Foundation

/// One short ping run, summarised: how much was lost and how long the rest took.
public struct PingSummary: Sendable, Equatable {
    /// 0...1.
    public var loss: Double
    /// Mean round trip in seconds, nil when nothing came back.
    public var averageRTT: TimeInterval?

    public init(loss: Double, averageRTT: TimeInterval?) {
        self.loss = loss
        self.averageRTT = averageRTT
    }

    /// "5 packets transmitted, 5 packets received, 0.0% packet loss" and
    /// "round-trip min/avg/max/stddev = 1.1/2.2/3.3/0.4 ms", the two summary lines
    /// every ping macOS has shipped prints with `-q`.
    public static func parse(_ output: String) -> PingSummary? {
        guard let lossMatch = output.range(of: #"(\d+(?:\.\d+)?)%\s+packet\s+loss"#, options: .regularExpression),
              let percent = Double(output[lossMatch].dropLast("% packet loss".count)) else { return nil }
        var average: TimeInterval?
        if let rtt = output.range(of: #"= [0-9.]+/([0-9.]+)/"#, options: .regularExpression) {
            let fields = output[rtt].dropFirst(2).split(separator: "/")
            if fields.count >= 2, let ms = Double(fields[1]) { average = ms / 1000 }
        }
        return PingSummary(loss: percent / 100, averageRTT: average)
    }
}

/// Round trip to the router, probed only while the panel is open.
///
/// The other half of "is it the Wi-Fi or is it the provider": the latency and loss
/// probes time the path to the internet, and this times the first hop of it. A slow
/// router means the local link; a quick router and a slow internet means the
/// trouble is past the router.
///
/// Same rules as `PacketLossProbe`, whose sibling it is: a short `/sbin/ping` run, at
/// most every fifteen seconds while someone is looking, cached under a lock so the
/// sampling queue pays a lock and nothing else.
public final class RouterProbe: @unchecked Sendable {

    public static let refreshInterval: TimeInterval = 15
    /// Five requests, five a second, inside a three-second ceiling: a router on the
    /// same link answers in a few milliseconds, so this is over in about a second.
    public static let pingArguments = ["-c", "5", "-i", "0.2", "-t", "3", "-n", "-q"]

    private let lock = NSLock()
    private var isEnabled = false
    private var target: String?
    private var state: MetricState<PingSummary> = .failure(.unsupported("panel is closed"))
    private var lastAttempt: ContinuousClock.Instant?
    private var isFetching = false
    private var generation: UInt64 = 0

    public init() {}

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

    /// The router to time. A new address starts over, so a reading from the last
    /// network is never shown for this one.
    public func setTarget(_ address: String?) {
        lock.lock()
        defer { lock.unlock() }
        guard address != target else { return }
        target = address
        generation &+= 1
        lastAttempt = nil
        isFetching = false
        state = isEnabled ? (address == nil ? .failure(.unsupported("no router")) : .pending)
                          : .failure(.unsupported("panel is closed"))
    }

    public func currentState() -> MetricState<PingSummary> {
        lock.lock()
        defer { lock.unlock() }
        return state
    }

    public func refreshIfDue() {
        lock.lock()
        guard isEnabled, !isFetching, let target,
              lastAttempt.map({ Monotonic.seconds(since: $0) >= Self.refreshInterval }) ?? true
        else {
            lock.unlock()
            return
        }
        isFetching = true
        lastAttempt = Monotonic.now
        let generation = self.generation
        lock.unlock()

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/sbin/ping")
        process.arguments = Self.pingArguments + [target]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] process in
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let result: MetricState<PingSummary>
            if process.terminationStatus == 0 || process.terminationStatus == 2,
               let summary = PingSummary.parse(text) {
                result = .value(summary)
            } else {
                result = .failure(.failed("ping exited \(process.terminationStatus)"))
            }
            self?.finish(result, generation: generation)
        }
        do {
            try process.run()
        } catch {
            finish(.failure(.failed("ping could not start")), generation: generation)
        }
    }

    private func finish(_ result: MetricState<PingSummary>, generation: UInt64) {
        lock.lock()
        defer { lock.unlock() }
        guard generation == self.generation, isEnabled else { return }
        isFetching = false
        state = result
    }
}

/// Whose fault a slow connection is, from the router's round trip and the
/// internet's.
public enum NetworkDiagnosis: Equatable, Sendable {
    /// Both answer quickly and nothing is lost.
    case healthy
    /// The router itself is slow or dropping packets: the local link is the trouble.
    case localLink(routerRTT: TimeInterval?, routerLoss: Double)
    /// The router is quick and the internet is not: the trouble is past the router.
    case provider(internetRTT: TimeInterval?, internetLoss: Double?)

    /// Over this, a router on the same link is not answering like one.
    static let slowRouter: TimeInterval = 0.030
    static let quickRouter: TimeInterval = 0.015
    /// Over this, the internet is slow enough to feel.
    static let slowInternet: TimeInterval = 0.150
    static let lossyLink = 0.05

    /// Nil while a reading is missing or when the answer would be a guess: a router
    /// that answers no ping at all is more often one that ignores pings than one
    /// that is down, so it says nothing either way.
    public static func make(router: MetricState<PingSummary>,
                            internetLatency: MetricState<TimeInterval>,
                            internetLoss: MetricState<Double>) -> NetworkDiagnosis? {
        guard let router = router.value, router.loss < 1, let routerRTT = router.averageRTT else { return nil }
        let internetRTT = internetLatency.value
        let loss = internetLoss.value
        guard internetRTT != nil || loss != nil else { return nil }

        if routerRTT > slowRouter || router.loss >= lossyLink {
            return .localLink(routerRTT: routerRTT, routerLoss: router.loss)
        }
        let internetBad = (internetRTT ?? 0) > slowInternet || (loss ?? 0) >= lossyLink
        if internetBad && routerRTT <= quickRouter {
            return .provider(internetRTT: internetRTT, internetLoss: loss)
        }
        if !internetBad { return .healthy }
        return nil
    }
}
