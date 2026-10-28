import Testing
import Foundation
import AppKit
@testable import AirStatKit
@testable import AirStatUI

/// The status item is repainted once per menu bar AppKit mirrors it into: one per
/// display and per full-screen Space. Measured at 48 paints per model change on a
/// two-display Mac, so every redraw that is not needed is paid dozens of times over.
/// These hold each of the ways the redraw count was brought down.
@Suite("Redraws are paid only for changes someone can see")
@MainActor
struct RedrawBudgetTests {

    private func model(_ items: [MenuBarItemConfig], cpu: Double) -> MenuBarRenderModel {
        var snapshot = SnapshotFixtures.nominal
        if var value = snapshot.cpu.value {
            value.total.user = cpu
            value.total.system = 0
            value.total.idle = 1 - cpu
            value.total.nice = 0
            snapshot.cpu = .value(value)
        }
        return MenuBarRenderModel(snapshot: snapshot, history: MetricHistory(),
                                  settings: Settings(menuBar: MenuBarSettings(items: items)),
                                  isStale: false)
    }

    @Test("a bar level that moves less than a step does not redraw")
    func subPixelLevelIsNotARedraw() {
        let bar = [MenuBarItemConfig(metric: .cpuUsage, style: .bar, showsCaption: false)]
        let view = MenuBarContentView(frame: .zero)
        #expect(view.update(with: model(bar, cpu: 0.341)))
        #expect(!view.update(with: model(bar, cpu: 0.343)))
        #expect(view.update(with: model(bar, cpu: 0.60)))
    }

    /// The bar draws no number, so its number changing is not a change. The text test
    /// is the control: the same move on a text readout must still redraw.
    @Test("a number the style does not draw does not redraw")
    func undrawnTextIsNotARedraw() {
        let bar = [MenuBarItemConfig(metric: .cpuUsage, style: .bar, showsCaption: false)]
        let a = model(bar, cpu: 0.3401)
        var b = a
        b.items[0].primary.valueText = "35%"
        b.items[0].accessibilityLabel = "CPU usage 35%"
        let view = MenuBarContentView(frame: .zero)
        view.update(with: a)
        #expect(!view.update(with: b))

        let text = [MenuBarItemConfig(metric: .cpuUsage, style: .text, showsCaption: false)]
        let textView = MenuBarContentView(frame: .zero)
        textView.update(with: model(text, cpu: 0.34))
        #expect(textView.update(with: model(text, cpu: 0.36)))
    }

    @Test("one model is rendered once per scale, however often it is painted")
    func paintsAreCachedPerScale() throws {
        let text = [MenuBarItemConfig(metric: .cpuUsage, style: .text, showsCaption: true)]
        let view = MenuBarContentView(frame: NSRect(x: 0, y: 0, width: 80, height: 22))
        view.update(with: model(text, cpu: 0.34))

        func paint(scale: CGFloat) throws {
            let context = try #require(CGContext(
                data: nil, width: Int(80 * scale), height: Int(22 * scale),
                bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.scaleBy(x: scale, y: scale)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            view.draw(view.bounds)
            NSGraphicsContext.restoreGraphicsState()
        }

        for _ in 0..<24 { try paint(scale: 2) }
        for _ in 0..<24 { try paint(scale: 1) }
        #expect(view.renderCount == 2)

        view.update(with: model(text, cpu: 0.80))
        try paint(scale: 2)
        #expect(view.renderCount == 3, "a new model has to be rendered again")
    }

    @Test("the menu bar temperature holds until the reading clearly leaves it")
    func temperatureHysteresis() {
        let steady = StatusItemController.steadiedTemperature
        #expect(steady(52.4, nil) == 52)
        // Dithering across the rounding boundary keeps the shown degree.
        #expect(steady(52.6, 52) == 52)
        #expect(steady(51.3, 52) == 52)
        // A real move is shown, rounded.
        #expect(steady(52.8, 52) == 53)
        #expect(steady(50.0, 52) == 50)
    }
}

@Suite("A menu bar on an idle machine samples at half rate")
struct QuietCadenceTests {

    @Test("quiet below the entry threshold, only with the menu bar alone")
    func entersOnlyForTheMenuBar() {
        let below = SamplingCore.quietEnterBusy - 0.01
        #expect(SamplingCore.isQuiet(activity: .menuBar, busy: below, wasQuiet: false))
        #expect(!SamplingCore.isQuiet(activity: .panel, busy: below, wasQuiet: false))
        #expect(!SamplingCore.isQuiet(activity: .desktopWidget, busy: below, wasQuiet: false))
        #expect(!SamplingCore.isQuiet(activity: .menuBar, busy: nil, wasQuiet: false))
    }

    /// Between the two thresholds the state it is in is the state it keeps, so a load
    /// hovering at one of them does not reschedule the timer on every tick.
    @Test("between the thresholds the cadence stays where it is")
    func hysteresis() {
        let between = (SamplingCore.quietEnterBusy + SamplingCore.quietExitBusy) / 2
        #expect(SamplingCore.isQuiet(activity: .menuBar, busy: between, wasQuiet: true))
        #expect(!SamplingCore.isQuiet(activity: .menuBar, busy: between, wasQuiet: false))
        #expect(!SamplingCore.isQuiet(activity: .menuBar,
                                      busy: SamplingCore.quietExitBusy + 0.01, wasQuiet: true))
    }
}
