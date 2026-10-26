import Testing
import Foundation
@testable import AirStatKit

@Suite("Packet loss summary")
struct PacketLossTests {

    @Test("the shipped ping summary parses to a fraction")
    func interpret() {
        let clean = PacketLossProbe.interpret(
            "10 packets transmitted, 10 received, 0.0% packet loss\n")
        #expect(clean.value == 0)
        let flaky = PacketLossProbe.interpret(
            "10 packets transmitted, 7 received, 30.0% packet loss\n")
        #expect(flaky.value == 0.3)
        let nothing = PacketLossProbe.interpret(
            "10 packets transmitted, 0 received, 100.0% packet loss\n")
        #expect(nothing.value == 1)
        #expect(PacketLossProbe.interpret("ping: cannot resolve host").value == nil)
    }

    @Test("nothing is sent while the panel is closed")
    func gated() {
        final class Requests: @unchecked Sendable { var count = 0 }
        let requests = Requests()
        let probe = PacketLossProbe { completion in
            requests.count += 1
            completion(.value(0))
        }
        for _ in 0..<5 { probe.refreshIfDue() }
        #expect(requests.count == 0)
        #expect(probe.currentState().isPermanentlyUnavailable)

        probe.setEnabled(true)
        probe.refreshIfDue()
        #expect(requests.count == 1)
        #expect(probe.currentState().value == 0)
    }
}
