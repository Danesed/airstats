import Testing
import Foundation
import SwiftUI
@testable import MuStatsKit
@testable import MuStatsUI

@Suite("Panel module order")
struct PanelModuleOrderTests {

    @Test("with nothing stored the order is the declaration order")
    func defaultOrder() {
        #expect(PanelSettings().visibleModules == PanelModule.allCases)
    }

    @Test("a stored order is kept, and modules it does not name follow")
    func partialOrderAppendsTheRest() {
        let panel = PanelSettings(moduleOrder: [.battery, .cpu, .battery])
        #expect(panel.visibleModules.prefix(2) == [.battery, .cpu])
        #expect(panel.visibleModules.count == PanelModule.allCases.count)
        #expect(Set(panel.visibleModules) == Set(PanelModule.allCases))
    }

    @Test("a dragged module takes the place of the one it is dropped on")
    func dropTakesTargetsPlace() {
        let panel = PanelSettings()
        let up = panel.moduleOrder(moving: .battery, before: .cpu)
        #expect(up.first == .battery)
        #expect(up[1] == .cpu)
        let down = panel.moduleOrder(moving: .cpu, before: .gpu)
        #expect(down.prefix(3) == [.memory, .gpu, .cpu])
        #expect(panel.moduleOrder(moving: .cpu, before: .cpu) == PanelModule.allCases)
    }

    @Test("the order round trips, and files written before it decode empty")
    func codable() throws {
        let panel = PanelSettings(moduleOrder: [.system, .cpu])
        let decoded = try JSONDecoder().decode(PanelSettings.self, from: JSONEncoder().encode(panel))
        #expect(decoded.moduleOrder == [.system, .cpu])
        let old = try JSONDecoder().decode(PanelSettings.self, from: Data("{}".utf8))
        #expect(old.moduleOrder.isEmpty)
    }
}

@Suite("Panel headline units")
struct PanelUsedOfTotalTests {
    private let formatter = MetricFormatter()
    private let gib = 1_073_741_824.0

    @Test("a used figure in another unit is expressed in the total's")
    func mixedUnits() {
        #expect(PanelSummary.usedOfTotal(1006 * 1_048_576, 13 * gib, formatter: formatter) == "1.0/13 GB")
    }

    @Test("same unit reads as before")
    func sameUnit() {
        #expect(PanelSummary.usedOfTotal(10 * gib, 18 * gib, formatter: formatter) == "10/18 GB")
        #expect(PanelSummary.usedOfTotal(8.6 * gib, 18 * gib, formatter: formatter) == "8.6/18 GB")
    }
}

@Suite("Panel culprit")
struct PanelCulpritTests {

    @Test("an app's helpers are counted under the app")
    func helpersAddUp() {
        let chrome = "/Applications/Google Chrome.app/Contents/Frameworks/Helpers/"
        let processes = [
            ProcessRow(pid: 1, name: "Google Chrome Helper (Renderer)",
                       executablePath: chrome + "Renderer.app/Contents/MacOS/Renderer", memoryBytes: 600),
            ProcessRow(pid: 2, name: "Google Chrome Helper",
                       executablePath: chrome + "Helper.app/Contents/MacOS/Helper", memoryBytes: 600),
            ProcessRow(pid: 3, name: "kernel_task", memoryBytes: 1000),
        ]
        let top = PanelCulprit.top(processes) { Double($0.memoryBytes) }
        #expect(top == PanelCulprit.Entry(name: "Google Chrome", value: 1200))
    }

    @Test("nothing using the resource names nobody")
    func idleNamesNobody() {
        let processes = [ProcessRow(pid: 1, name: "idle", cpuPercent: 0)]
        #expect(PanelCulprit.top(processes, by: \.cpuPercent) == nil)
    }
}

@MainActor
@Suite("Panel insight")
struct PanelInsightTests {

    private func engine(_ snapshot: SystemSnapshot) -> MetricsEngine {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PanelInsightTests-\(UUID().uuidString)")
        let engine = MetricsEngine(settingsStore: SettingsStore(directory: dir))
        engine.loadFixture(snapshot: snapshot, history: MetricHistory())
        return engine
    }

    @Test("a calm machine says so and points nowhere")
    func quiet() {
        let insight = PanelInsight.make(modules: PanelModule.allCases, engine: engine(SnapshotFixtures.nominal),
                                        formatter: MetricFormatter())
        #expect(insight == .quiet)
    }

    @Test("under load the worst module speaks, memory first among equals, naming the app")
    func underLoad() {
        let insight = PanelInsight.make(modules: PanelModule.allCases,
                                        engine: engine(SnapshotFixtures.underLoad),
                                        formatter: MetricFormatter())
        #expect(insight.level == .critical)
        #expect(insight.module == .memory)
        #expect(insight.detail != nil)
    }

    @Test("a module not in the panel cannot speak")
    func onlyVisibleModules() {
        let insight = PanelInsight.make(modules: [.network, .system],
                                        engine: engine(SnapshotFixtures.underLoad),
                                        formatter: MetricFormatter())
        #expect(insight == .quiet)
    }
}

@Suite("History gaps")
struct HistoryGapTests {

    private func plot(_ columns: [BandColumn?]) -> BandPlot {
        BandPlot(rect: CGRect(x: 0, y: 0, width: 100, height: 40),
                 scale: ChartScale(upperBound: 1, isDerived: false, peak: 1), columns: columns)
    }

    @Test("only a stretch with samples on both sides is a gap")
    func interiorOnly() {
        let c = BandColumn(low: 0.1, mean: 0.2, high: 0.3)
        #expect(plot([nil, nil, c, c, nil, nil, c, nil]).interiorGaps == [4..<6])
        #expect(plot([nil, c, c, c]).interiorGaps.isEmpty)
    }
}

@Suite("Today's events")
struct PanelEventTests {

    private func series(_ means: [Float], key: SeriesKey = .cpuTotal, notes: [Int: String] = [:]) -> MinuteSeries {
        MinuteSeries(key: key, minima: means, averages: means, maxima: means,
                     counts: means.map { $0 < 0 ? 0 : 1 }, notes: notes,
                     end: Date(timeIntervalSince1970: 86_400))
    }

    private var cpu: PanelEvents.Rule { PanelEvents.rules[0] }

    @Test("a stretch above the line becomes one event, named by its most frequent process")
    func stretch() {
        let s = series([0.2, 0.85, 0.97, 0.9, 0.2, 0.2, 0.2, 0.2],
                       notes: [1: "swift-frontend", 2: "swift-frontend", 3: "Xcode"])
        let events = PanelEvents.detect(series: s, notes: s, rule: cpu)
        #expect(events.count == 1)
        #expect(events.first?.level == .critical)
        #expect(events.first?.culprit == "swift-frontend")
        #expect(abs((events.first?.peak ?? 0) - 0.97) < 0.001)
    }

    @Test("a one-minute spike is not an event, and a short dip does not split one")
    func spikesAndDips() {
        let spike = series([0.2, 0.99, 0.2, 0.2, 0.2, 0.2])
        #expect(PanelEvents.detect(series: spike, notes: spike, rule: cpu).isEmpty)
        let dip = series([0.9, 0.9, 0.3, 0.9, 0.9, 0.2, 0.2, 0.2, 0.2])
        #expect(PanelEvents.detect(series: dip, notes: dip, rule: cpu).count == 1)
    }

    @Test("minutes never sampled do not count as above the line")
    func unsampled() {
        let s = series([-1, -1, -1, -1])
        #expect(PanelEvents.detect(series: s, notes: s, rule: cpu).isEmpty)
    }
}
