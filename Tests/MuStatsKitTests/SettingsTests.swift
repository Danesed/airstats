import Testing
import Foundation
@testable import MuStatsKit

@Suite("Settings decoding is fault tolerant")
struct SettingsDecodingTests {

    private func decode(_ json: String) throws -> Settings {
        try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
    }

    @Test("an empty object yields full defaults")
    func emptyObject() throws {
        let settings = try decode("{}")
        #expect(settings.general.updateInterval == 2)
        #expect(settings.menuBar.items.count == MenuBarSettings.defaultItems.count)
        #expect(settings.panel.collapsedModules == PanelSettings.defaultCollapsed)
    }

    @Test("a desktop widget layer round-trips")
    func desktopWidgetDepthRoundTrips() throws {
        var settings = Settings()
        settings.desktopWidget.depth = .wallpaper
        let data = try JSONEncoder().encode(settings)
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("desktopWidget"))
        #expect(try JSONDecoder().decode(Settings.self, from: data).desktopWidget.depth == .wallpaper)
    }

    /// Asserted by content, not against the constant the app reads. The defaults check
    /// above compares `collapsedModules` to `PanelSettings.defaultCollapsed`, which
    /// stays true no matter what that constant is changed to and so cannot notice a
    /// module quietly starting open.
    @Test("the panel opens with every module closed")
    func panelStartsFullyCollapsed() {
        let collapsed = PanelSettings().collapsedModules
        for module in PanelModule.allCases {
            #expect(collapsed.contains(module), "\(module.label) starts open")
        }
    }

    /// Opening a module closes the one that was open, and closing the open module
    /// leaves the list fully collapsed.
    @Test("the panel keeps one module open at a time")
    func panelIsAnAccordion() {
        var panel = PanelSettings()
        panel.collapsedModules = panel.collapsedModules(toggling: .cpu)
        #expect(panel.collapsedModules == Set(PanelModule.allCases).subtracting([.cpu]))
        panel.collapsedModules = panel.collapsedModules(toggling: .memory)
        #expect(panel.collapsedModules == Set(PanelModule.allCases).subtracting([.memory]))
        panel.collapsedModules = panel.collapsedModules(toggling: .memory)
        #expect(panel.collapsedModules == Set(PanelModule.allCases))
    }

    /// A file saved before the accordion can hold several open modules. The first in
    /// panel order stays open rather than all of them closing, so an upgrade does not
    /// hand back a panel that has forgotten what the user was looking at.
    @Test("a stored panel with several open modules keeps the first")
    func panelCollapsesAllButTheFirstOpenModule() throws {
        let settings = try decode(#"{"panel":{"collapsedModules":["cpu","gpu"]}}"#)
        #expect(settings.panel.collapsedModules == Set(PanelModule.allCases).subtracting([.memory]))
    }

    @Test("a fresh install opens at login, an existing one keeps its answer")
    func launchAtLoginDefault() throws {
        // The shipped default, which is what a Mac with no settings file gets.
        #expect(GeneralSettings().launchAtLogin)
        // A file that already says no must stay no. The default changed after release,
        // and re-enabling a login item someone deliberately turned off would be the
        // worst possible reading of "default it to on".
        #expect(try decode(#"{"general":{"launchAtLogin":false}}"#).general.launchAtLogin == false)
        // A file predating the key is an existing install too, so it does not opt in.
        #expect(try decode(#"{"general":{}}"#).general.launchAtLogin == false)
    }

    @Test("a malformed key falls back without losing its siblings")
    func malformedKeyIsIsolated() throws {
        let settings = try decode("""
        {"general":{"updateInterval":"not a number","launchAtLogin":true,"temperatureUnit":"kelvin"}}
        """)
        #expect(settings.general.updateInterval == 2)          // fell back
        #expect(settings.general.launchAtLogin == true)        // survived
        #expect(settings.general.temperatureUnit == .celsius)  // unknown enum fell back
    }

    @Test("out-of-range values are clamped, not accepted")
    func clamping() throws {
        let settings = try decode("""
        {"general":{"updateInterval":9999},
         "desktopWidget":{"opacity":0.0,"width":10000},
         "charts":{"historyDuration":999999}}
        """)
        #expect(settings.general.updateInterval == 60)
        #expect(settings.desktopWidget.opacity == 0.2)   // never invisible
        #expect(settings.desktopWidget.width == 480)
        #expect(settings.charts.historyDuration == 3600)
    }

    @Test("an empty menu bar is repaired so the app stays reachable")
    func emptyMenuBarIsRepaired() throws {
        let settings = try decode(#"{"menuBar":{"items":[]}}"#)
        #expect(!settings.menuBar.items.isEmpty)
        #expect(!settings.menuBar.enabledItems.isEmpty)
    }

    @Test("every item disabled still leaves one enabled after sanitising")
    func allDisabledIsRepaired() {
        var settings = Settings()
        for index in settings.menuBar.items.indices { settings.menuBar.items[index].isEnabled = false }
        let sanitized = SettingsStore.sanitize(settings)
        #expect(sanitized.menuBar.enabledItems.count == 1)
    }

    @Test("a style the metric no longer supports is corrected")
    func incompatibleStyleIsCorrected() {
        // Uptime keeps no series, so there is nothing for a graph to plot.
        let item = MenuBarItemConfig(metric: .uptime, style: .graph)
        #expect(!MenuBarMetric.uptime.supportedStyles.contains(.graph))
        #expect(item.sanitized().style != .graph)
    }

    @Test("an unsupported style in a stored file lands on one the metric supports")
    func unsupportedStyleIsSanitized() throws {
        let settings = try decode(#"{"menuBar":{"items":[{"metric":"cpuUsage","style":"ring"}]}}"#)
        #expect(MenuBarMetric.cpuUsage.supportedStyles.contains(settings.menuBar.items[0].style))
    }

    @Test("round-trips without loss")
    func roundTrip() throws {
        var original = Settings()
        original.general.temperatureUnit = .fahrenheit
        original.desktopWidget.isEnabled = true
        original.menuBar.items.append(MenuBarItemConfig(metric: .gpuUsage, style: .graph))
        let data = try JSONEncoder().encode(original)
        let restored = try JSONDecoder().decode(Settings.self, from: data)
        #expect(restored == original)
    }

    @Test("truncated JSON throws so the caller can fall back to the backup")
    func truncatedThrows() {
        #expect(throws: (any Error).self) {
            try decode("{\"general\":{\"updateInterval\":")
        }
    }
}

@Suite("Required sources track what is actually on screen")
struct RequiredSourceTests {

    @Test("only menu bar sources are needed when the panel is closed")
    func menuBarOnly() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        let sources = settings.requiredSources(panelVisible: false, desktopWidgetVisible: false)
        #expect(sources.contains(.cpu))
        #expect(!sources.contains(.power))     // nothing on screen needs the battery
        #expect(!sources.contains(.processes)) // the expensive one stays off
    }

    @Test("opening the panel pulls in its modules")
    func panelOpen() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        let sources = settings.requiredSources(panelVisible: true, desktopWidgetVisible: false)
        #expect(sources.contains(.processes))
        #expect(sources.contains(.power))
    }

    @Test("enabled notification rules keep their source alive")
    func notificationRulesRequireSources() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        settings.notifications.isEnabled = true
        settings.notifications.rules = [ThresholdRule(metric: .batteryLow, isEnabled: true)]
        let sources = settings.requiredSources(panelVisible: false, desktopWidgetVisible: false)
        #expect(sources.contains(.power))
    }

    @Test("watching the public IP keeps the network source alive")
    func publicIPWatchRequiresNetwork() {
        var settings = Settings()
        settings.menuBar.items = [MenuBarItemConfig(metric: .cpuUsage)]
        settings.notifications.isEnabled = true
        settings.notifications.notifiesOnPublicIPChange = true
        let sources = settings.requiredSources(panelVisible: false, desktopWidgetVisible: false)
        #expect(sources.contains(.network))
    }

    @Test("the public IP watch decodes off by default and round trips on")
    func publicIPWatchDecoding() throws {
        let defaults = try JSONDecoder().decode(NotificationSettings.self, from: Data("{}".utf8))
        #expect(defaults.notifiesOnPublicIPChange == false)
        var on = NotificationSettings()
        on.notifiesOnPublicIPChange = true
        let decoded = try JSONDecoder().decode(NotificationSettings.self,
                                               from: JSONEncoder().encode(on))
        #expect(decoded.notifiesOnPublicIPChange == true)
    }
}

@Suite("History capacity follows interval and retention")
struct HistoryCapacityTests {

    @Test("capacity covers the requested duration at the chosen interval")
    func capacity() {
        var settings = Settings()
        settings.general.updateInterval = 2
        settings.charts.historyDuration = 300
        #expect(settings.historyCapacity >= 150)
        #expect(settings.historyCapacity <= 160)
    }

    @Test("capacity stays bounded at the fastest interval and longest retention")
    func bounded() {
        var settings = Settings()
        settings.general.updateInterval = 0.5
        settings.charts.historyDuration = 3600
        // 7200 samples would be honest but wasteful; the cap keeps memory predictable.
        #expect(settings.historyCapacity == 4096)
    }

    @Test("miniGraph style is offered in general styles and shows a graph")
    func miniGraphStyleProperties() {
        #expect(MenuBarDisplayStyle.general.contains(.miniGraph))
        #expect(MenuBarDisplayStyle.miniGraph.showsGraph)
        #expect(MenuBarDisplayStyle.miniGraph.supportsCaption)
        #expect(MenuBarDisplayStyle.miniGraph.label == "Mini Graph")
        #expect(!MenuBarDisplayStyle.text.showsGraph)
        #expect(!MenuBarDisplayStyle.iconAndText.showsGraph)
    }

    @Test("showsAlertColors defaults to true and round trips in settings")
    func showsAlertColorsRoundTrip() throws {
        let defaults = Settings()
        #expect(defaults.panel.showsAlertColors == true)
        var off = Settings()
        off.panel.showsAlertColors = false
        let data = try JSONEncoder().encode(off)
        let decoded = try JSONDecoder().decode(Settings.self, from: data)
        #expect(decoded.panel.showsAlertColors == false)
    }
}
