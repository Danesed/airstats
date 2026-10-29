import Testing
@testable import MuStatsKit

@Suite("A temperature is only reported when a sensor in that place could read it")
struct ThermalPlausibilityTests {

    @Test("a die reading from a sensor still waking up is dropped")
    func wakingDieIsDropped() {
        #expect(!ThermalCollector.isPlausible(2.7, category: .cpu))
        #expect(!ThermalCollector.isPlausible(7.6, category: .gpu))
    }

    @Test("a running die is kept")
    func runningDieIsKept() {
        #expect(ThermalCollector.isPlausible(48.4, category: .cpu))
        #expect(ThermalCollector.isPlausible(33.0, category: .gpu))
    }

    @Test("a cold room still reads on ambient and battery sensors")
    func coldAmbientIsKept() {
        #expect(ThermalCollector.isPlausible(4.0, category: .ambient))
        #expect(ThermalCollector.isPlausible(4.0, category: .battery))
    }

    @Test("gated sentinels and impossible highs are dropped everywhere")
    func sentinelsAreDropped() {
        for category in [SensorCategory.cpu, .gpu, .ambient, .battery] {
            #expect(!ThermalCollector.isPlausible(-3.2, category: category))
            #expect(!ThermalCollector.isPlausible(0.0, category: category))
            #expect(!ThermalCollector.isPlausible(140, category: category))
        }
    }
}
