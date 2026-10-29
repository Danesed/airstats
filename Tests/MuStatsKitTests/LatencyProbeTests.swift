import Testing
import Foundation
@testable import MuStatsKit

/// Everything here runs against a stub transport. The one part of this feature that
/// needs the internet is the round trip itself; the parts worth guarding are the ones
/// that decide whether the round trip happens at all — the probe exists for the panel,
/// so a closed panel must mean no traffic.
@Suite("Latency probe")
struct LatencyProbeTests {

    /// Counts what would have left the machine and answers on demand, so a test can
    /// assert on requests without making one.
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var pending: [(MetricState<TimeInterval>) -> Void] = []
        private var requests = 0

        var transport: LatencyTransport {
            { [self] completion in
                lock.lock()
                requests += 1
                pending.append(completion)
                lock.unlock()
            }
        }

        var requestCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return requests
        }

        /// Completes every outstanding request with the same answer.
        func answer(_ state: MetricState<TimeInterval>) {
            lock.lock()
            let completions = pending
            pending.removeAll()
            lock.unlock()
            for completion in completions { completion(state) }
        }
    }

    @Test("nothing is sent while the panel is closed")
    func gatedOnPanelVisibility() {
        let recorder = Recorder()
        let probe = LatencyProbe(transport: recorder.transport)

        for _ in 0..<5 { probe.refreshIfDue() }

        #expect(recorder.requestCount == 0)
        // The panel keys the row's presence off this: closed means "no row", which is
        // why the probe reports unsupported rather than pending while it is off.
        #expect(probe.currentState().isPermanentlyUnavailable)
    }

    @Test("opening the panel produces exactly one in-flight probe")
    func oneProbeOnEnable() {
        let recorder = Recorder()
        let probe = LatencyProbe(transport: recorder.transport)

        probe.setEnabled(true)
        #expect(recorder.requestCount == 0)
        #expect(probe.currentState().failure == .pending)

        probe.refreshIfDue()
        #expect(recorder.requestCount == 1)

        // A second tick while the first request is still out must not open another.
        probe.refreshIfDue()
        #expect(recorder.requestCount == 1)

        recorder.answer(.value(0.031))
        #expect(probe.currentState().value == 0.031)
    }

    @Test("a cached reading is not re-probed on the next tick")
    func throttledAfterSuccess() {
        let recorder = Recorder()
        let probe = LatencyProbe(transport: recorder.transport)
        probe.setEnabled(true)
        probe.refreshIfDue()
        recorder.answer(.value(0.031))

        // The sampling queue calls this every second or two while the panel is open.
        for _ in 0..<50 { probe.refreshIfDue() }

        #expect(recorder.requestCount == 1)
        #expect(probe.currentState().value == 0.031)
    }

    /// The interval itself, because the justification for any outbound traffic at all
    /// is that it stays light. A future edit that drops this to every sample should
    /// fail here rather than ship.
    @Test("the throttle is measured in seconds, not samples")
    func intervalIsLong() {
        #expect(LatencyProbe.refreshInterval == 4)
    }

    @Test("closing the panel clears the reading and stops probes")
    func disablingClearsTheCache() {
        let recorder = Recorder()
        let probe = LatencyProbe(transport: recorder.transport)
        probe.setEnabled(true)
        probe.refreshIfDue()
        recorder.answer(.value(0.031))
        #expect(probe.currentState().value == 0.031)

        probe.setEnabled(false)

        #expect(probe.currentState().value == nil)
        #expect(probe.currentState().isPermanentlyUnavailable)
        for _ in 0..<5 { probe.refreshIfDue() }
        #expect(recorder.requestCount == 1)
    }

    @Test("a reply that arrives after the panel closed is discarded")
    func lateReplyIsDropped() {
        let recorder = Recorder()
        let probe = LatencyProbe(transport: recorder.transport)
        probe.setEnabled(true)
        probe.refreshIfDue()

        probe.setEnabled(false)
        recorder.answer(.value(0.031))

        #expect(probe.currentState().value == nil)
        #expect(probe.currentState().isPermanentlyUnavailable)
    }

    @Test("re-opening starts from pending, not from the old reading")
    func reenablingDoesNotShowStaleReading() {
        let recorder = Recorder()
        let probe = LatencyProbe(transport: recorder.transport)
        probe.setEnabled(true)
        probe.refreshIfDue()
        recorder.answer(.value(0.031))

        probe.setEnabled(false)
        probe.setEnabled(true)

        #expect(probe.currentState().failure == .pending)
        probe.refreshIfDue()
        #expect(recorder.requestCount == 2)
    }
}
