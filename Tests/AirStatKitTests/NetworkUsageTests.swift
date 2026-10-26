import Testing
import Foundation
@testable import AirStatKit

@Suite("Network usage ledger")
struct NetworkUsageTests {

    private func snapshot(up: UInt64, down: UInt64, ssid: String? = "Sunnyvale") -> NetworkSnapshot {
        NetworkSnapshot(totalUploadBytes: up, totalDownloadBytes: down,
                        primaryInterfaceName: "en0",
                        connectionType: ssid == nil ? .ethernet : .wifi,
                        wifi: ssid.map { WiFiInfo(ssid: $0) })
    }

    @Test("only the delta between two samples is attributed")
    func deltasOnly() {
        var ledger = NetworkUsageLedger()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        ledger.observe(snapshot(up: 1_000, down: 5_000), at: t)
        #expect(ledger.today.combined() == 0, "the first sample only baselines")
        ledger.observe(snapshot(up: 1_400, down: 5_900), at: t)
        #expect(ledger.today.upload == 400)
        #expect(ledger.today.download == 900)
        #expect(ledger.networks["Sunnyvale"]?.combined() == 1_300)
    }

    @Test("a counter that goes backwards is a reboot, not negative traffic")
    func rebootResets() {
        var ledger = NetworkUsageLedger()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        ledger.observe(snapshot(up: 1_000_000_000, down: 1_000_000_000), at: t)
        ledger.observe(snapshot(up: 500, down: 500), at: t)
        #expect(ledger.today.combined() == 0, "the rebooted counters re-baseline")
        ledger.observe(snapshot(up: 700, down: 900), at: t)
        #expect(ledger.today.combined() == 600)
    }

    @Test("a new day key resets today but keeps the network totals")
    func dayRollover() {
        var ledger = NetworkUsageLedger()
        let day1 = Date(timeIntervalSince1970: 1_700_000_000)
        let day2 = day1.addingTimeInterval(86_400)
        ledger.observe(snapshot(up: 0, down: 0), at: day1)
        ledger.observe(snapshot(up: 100, down: 200), at: day1)
        #expect(ledger.today.combined() == 300)
        ledger.observe(snapshot(up: 200, down: 400), at: day2)
        #expect(ledger.today.combined() == 300, "today restarted at midnight")
        #expect(ledger.total.combined() == 600, "the all-time total did not")
        #expect(ledger.networks["Sunnyvale"]?.combined() == 600, "the network did not")
    }

    @Test("a file written before the total column decodes with it at zero")
    func oldFileDecodes() throws {
        let old = Data(#"{"dayKey":"2026-10-25","today":{"upload":1,"download":2},"networks":{}}"#.utf8)
        let ledger = try JSONDecoder().decode(NetworkUsageLedger.self, from: old)
        #expect(ledger.today.combined() == 3)
        #expect(ledger.total.combined() == 0)
    }

    @Test("no network name, no per-network bucket")
    func offlineAttributesToTodayOnly() {
        var ledger = NetworkUsageLedger()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        let offline = { up, down in NetworkSnapshot(
            totalUploadBytes: up, totalDownloadBytes: down, connectionType: .none) }
        ledger.observe(offline(0, 0), at: t)
        ledger.observe(offline(100, 100), at: t)
        #expect(ledger.today.combined() == 200)
        #expect(ledger.networks.isEmpty)
    }

    @Test("the ledger survives its own file")
    func fileRoundTrip() {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AirStatTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = NetworkUsageFile(directory: dir)
        var ledger = NetworkUsageLedger()
        let t = Date(timeIntervalSince1970: 1_700_000_000)
        ledger.observe(snapshot(up: 0, down: 0), at: t)
        ledger.observe(snapshot(up: 700, down: 900), at: t)
        file.save(ledger)
        let restored = file.load()
        #expect(restored.today == ledger.today)
        #expect(restored.networks == ledger.networks)
        // The counters are not persisted: a relaunch re-baselines from the kernel's
        // totals rather than crediting whatever moved while the app was off.
        #expect(restored.lastUpload == nil)
    }
}
