import SwiftUI
import AppKit
import AirStatKit

/// The one-glance answer for a module, shown on its header line.
///
/// Everything below the header is detail the user reads second; this is what they
/// read first, so each module contributes exactly one of them.
struct PanelSummary {
    /// Whether the primary reads as a measurement or as a state. A state ("Nominal",
    /// "AC") set at headline size looks like a mistake, so it drops to value size.
    enum Emphasis { case measurement, state }

    var value: String?
    var caption: String?
    /// Replaces the module's own glyph. A full battery icon on a Mac that has no
    /// battery states something untrue before the reader gets to the words.
    var icon: String?
    var symbol: String?
    /// A second reading that leads `value`, direction glyph and all. Only
    /// network answers with two rates — "↗ 340 KB/s  ↙ 2.4 MB/s"; everywhere
    /// else one number is the answer.
    var leadValue: String?
    var leadSymbol: String?
    var emphasis: Emphasis = .measurement
    /// Text the headline slot is sized for before it is on screen, drawn hidden at
    /// the size the real reading will use. Only a module whose headline swaps a
    /// state for a measurement mid-session asks for one: without them the
    /// "Apple M4 Pro" → "84%" handover moves the whole row, and measured reserves
    /// drift a point or two from what the layout actually grants a `Text`.
    var reservedHeadlineText: String?
    var reservedValueText: String?
}

/// One module of the panel: a header that carries the headline value, and detail
/// that the user can collapse away.
struct PanelModuleView: View {
    let module: PanelModule
    let engine: MetricsEngine
    let settings: SettingsStore
    var layout: PanelLayoutState?
    /// Width of the qualifier column beside the headline value, shared by every row so
    /// the numbers keep one right edge. See `PanelSummary.captionColumnWidth(for:)`.
    var captionColumnWidth: CGFloat

    @State private var isHovering = false
    /// Which window the module's history chart shows, once the user has picked one.
    /// View state rather than a setting: it is a glance choice, and it resets with
    /// the panel. Nil lets the chart choose by how much of the day exists.
    @State var historyRange: HistoryRange?

    /// Derived from the store rather than read from the environment so a module is
    /// correct wherever it is hosted, and injected below so the primitives it draws
    /// cannot disagree with it.
    var formatter: MetricFormatter {
        MetricFormatter(settings: settings.settings.general)
    }

    var isExpanded: Bool {
        let collapsed = layout?.collapsedModulesOverride
            ?? settings.settings.panel.collapsedModules
        return !collapsed.contains(module)
    }

    /// What the panel fills its bars and core cells with.
    ///
    /// The label colour, not `Palette.metric`. Nine modules each in their own hue is
    /// nine colours competing in a 340pt window, and the bar is the content here —
    /// nothing sits on top of it — so it takes the colour text takes.
    static let barTint = Design.Palette.primaryText

    var tint: Color { Self.barTint }

    /// The history chart stays a step quieter than the bars: a stroked line reads at
    /// secondary weight where a filled bar does not.
    var chartTint: Color { Design.Palette.secondaryText }

    /// The low-to-high band of the history chart, under its mean line. Fainter than
    /// a bar's fill: it is context for the line, not a reading of its own.
    var bandTint: Color { Design.Palette.primaryText.opacity(0.10) }

    /// A module glyph is a thin shape beside a heading it does not compete with, so it
    /// sits at secondary weight — nine icons at full strength is a wall.
    private var iconColor: Color { Design.Palette.secondaryText }

    /// Reserved width for the process list's value column, sized for the widest
    /// reading it can hold ("412.6%", "4.3 GB") so the column never reflows as
    /// processes come and go.
    static let processValueWidth: CGFloat = 52

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            detail
                .padding(.horizontal, Design.Space.panelInset)
                .padding(.top, Design.Space.xxs)
        }
        .padding(.vertical, Design.Space.xxs)
        .environment(\.metricFormatter, formatter)
        .environment(\.isDisclosureInProgress, layout?.isDisclosureTransitionActive == true)
    }

    // MARK: Header

    private var header: some View {
        Button(action: toggleCollapsed) {
            HStack(spacing: Design.Space.m) {
                Image(systemName: "chevron.right")
                    .font(Design.Text.micro.weight(.semibold))
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Design.Space.m)
                Image(systemName: summary.icon ?? module.symbolName)
                    .font(Design.Text.sectionHeader)
                    .foregroundStyle(iconColor)
                    .frame(width: Design.Space.xl)
                Text(module.label)
                    .font(Design.Text.sectionHeader)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
                Spacer(minLength: Design.Space.s)
                headlineValue
                    // The number outranks the gap in front of it: without this the
                    // `HStack` splits any shortfall between the `Spacer` and the value,
                    // so "7.4 GB" could render as "7.4…" with slack sitting unused to
                    // its left.
                    .layoutPriority(1)
            }
            .padding(.horizontal, Design.Space.panelInset)
            .contentShape(Rectangle())
            .background(hoverHighlight)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(module.label)
        .accessibilityValue([summary.leadValue, summary.value].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(isExpanded ? "Collapse" : "Expand")
    }

    @ViewBuilder
    private var hoverHighlight: some View {
        RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
            // Rows move under a stationary pointer during disclosure. Hiding the
            // highlight while they travel prevents it flashing from one row to the
            // next; onHover still tracks the final row underneath for the next frame.
            .fill(isHovering && layout?.isDisclosureTransitionActive != true
                  ? Design.Palette.track : .clear)
            .padding(.horizontal, Design.Space.s)
    }

    @ViewBuilder
    private var headlineValue: some View {
        if let value = summary.value {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.xs) {
                ZStack(alignment: .trailing) {
                    // Hidden sizers claim the exact slot the readings will occupy —
                    // same `Text`, same fonts, so the reservation cannot drift from
                    // the layout the way a hand-measured width can.
                    if let text = summary.reservedHeadlineText {
                        Text(text).font(Design.Text.headline).hidden()
                    }
                    if let text = summary.reservedValueText {
                        Text(text).font(Design.Text.value).hidden()
                    }
                    HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                        if let lead = summary.leadValue {
                            headlineReading(symbol: summary.leadSymbol, value: lead)
                        }
                        headlineReading(symbol: summary.symbol, value: value)
                    }
                }
                // The qualifier sits in a shared column so it cannot push the number.
                //
                // Inline, a caption shifted its value left by its own width, so across the
                // collapsed list the numbers ended at x = 254, 282, 285, 300, 323, 324 —
                // a 70pt ragged spread that made the column impossible to scan even though
                // the right edge looked tidy. Every row takes the slot whether or not it
                // has a caption, which puts every number's right edge on the same line.
                // When no row has one there is no column at all.
                if captionColumnWidth > 0 {
                    Text(summary.caption ?? "")
                        .font(Design.Text.caption)
                        .foregroundStyle(Design.Palette.tertiaryText)
                        .lineLimit(1)
                        .frame(width: captionColumnWidth, alignment: .leading)
                        .accessibilityHidden(summary.caption == nil)
                }
            }
        }
    }

    /// One glyph-and-number unit of the headline. Tight internally so the wider
    /// gap falls between two units, where a second reading needs to separate.
    @ViewBuilder
    private func headlineReading(symbol: String?, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Design.Space.xxs) {
            if let symbol {
                Image(systemName: symbol)
                    .font(Design.Text.caption.weight(.semibold))
                    .foregroundStyle(Design.Palette.secondaryText)
            }
            Text(value)
                .font(summary.emphasis == .measurement ? Design.Text.headline : Design.Text.value)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .contentTransition(.numericText())
        }
    }

    private func toggleCollapsed() {
        if let coordinate = layout?.toggleModule {
            coordinate(module)
            return
        }
        withAnimation(Design.Motion.respectingAccessibility(Design.Motion.disclosure)) {
            settings.update { s in
                s.panel.collapsedModules = s.panel.collapsedModules(toggling: module)
            }
        }
    }

    // MARK: Summary

    private var summary: PanelSummary {
        .make(for: module, engine: engine, formatter: formatter)
    }

}

extension PanelSummary {
    /// The one-glance answer for `module`, or an empty summary while it has nothing yet.
    @MainActor
    static func make(for module: PanelModule, engine: MetricsEngine,
                     formatter: MetricFormatter) -> PanelSummary {
        switch module {
        case .cpu:
            guard let cpu = engine.cpu.value else { return warmup(for: engine.cpu) }
            // The percentage alone cannot say whether work is queueing: 34% with a
            // load of 12 is a very different machine from 34% with a load of 1.
            return PanelSummary(value: formatter.percent(cpu.total.busy),
                                caption: "load " + formatter.fixed(cpu.loadAverage.one, decimals: 1))
        case .memory:
            guard let memory = engine.memory.value else { return warmup(for: engine.memory) }
            return PanelSummary(value: formatter.percent(memory.pressureFraction),
                                caption: formatter.memory(memory.usedBytes))
        case .gpu:
            guard let gpu = engine.gpu.value else { return warmup(for: engine.gpu) }
            guard let device = gpu.primary else { return PanelSummary() }
            // The bare figure, not "Memory 5.4 GB": a caption labels what is on
            // its row, and a caption that long widens the shared caption column
            // enough to squeeze the module labels into ellipses.
            let vram = device.vramUsedBytes.map { formatter.memory($0) }
            // The handover swaps a state-size name for a headline-size number, so
            // the slot is sized for both from the start and only the text moves.
            guard let utilization = device.utilization else {
                return PanelSummary(value: device.name, caption: vram,
                                    emphasis: .state,
                                    reservedHeadlineText: formatter.percent(1.0),
                                    reservedValueText: device.name)
            }
            // Device identity belongs in the expanded detail: it is the only
            // caption long enough to break the column.
            return PanelSummary(value: formatter.percent(utilization), caption: vram,
                                reservedHeadlineText: formatter.percent(1.0),
                                reservedValueText: device.name)
        case .network:
            guard let network = engine.network.value else { return warmup(for: engine.network) }
            // The paired headline is already the widest in the panel; even a short
            // SSID here widens the shared caption column enough to squeeze this
            // row's own label into an ellipsis. The connection kind only reports
            // when there is no Wi-Fi row below to carry the network's name.
            return PanelSummary(value: formatter.networkRate(network.downloadBytesPerSecond),
                                caption: network.wifi == nil ? network.connectionType.label : nil,
                                symbol: "arrow.down.left",
                                leadValue: formatter.networkRate(network.uploadBytesPerSecond),
                                leadSymbol: "arrow.up.right")
        case .disk:
            guard let disk = engine.disk.value else { return warmup(for: engine.disk) }
            guard let root = disk.rootVolume else { return PanelSummary() }
            // The caption is the value's twin in the other unit: "120 GB" and
            // "24% free" are one answer, so it is measured from the same bytes.
            let freeFraction = root.totalBytes > 0
                ? Double(root.availableBytes) / Double(root.totalBytes) : 0
            return PanelSummary(value: formatter.storage(root.availableBytes),
                                caption: formatter.percent(freeFraction) + " free")
        case .battery:
            guard let power = engine.power.value else { return warmup(for: engine.power) }
            guard power.hasBattery, let percentage = power.percentage else {
                return PanelSummary(value: power.isPluggedIn ? "AC" : MetricFormatter.unavailable,
                                    icon: "powerplug",
                                    emphasis: .state)
            }
            // The caption is the pack's instantaneous power: on battery it is the
            // system draw, on AC it is the charge rate — which also carries the
            // "is it charging" answer the old "charging" caption held, in a number.
            return PanelSummary(value: formatter.percentValue(percentage),
                                caption: power.batteryWatts.map { formatter.watts(abs($0)) },
                                icon: power.isCharging || power.isPluggedIn ? "powerplug" : nil)
        case .thermal:
            guard let thermal = engine.thermal.value else { return warmup(for: engine.thermal) }
            // The caption is the fastest fan: a temperature is only half the story,
            // and "52°C" reads very differently depending on whether the fans have
            // answered. "fan 1820" rather than "1,820 RPM" — the unit suffix would
            // widen the shared caption column enough to squeeze module labels.
            let fan = thermal.fans.max { $0.currentRPM < $1.currentRPM }
                .map { "fan \(Int($0.currentRPM.rounded()))" }
            guard let celsius = thermal.cpuCelsius else {
                return PanelSummary(value: thermal.pressure.label, caption: fan,
                                    emphasis: .state)
            }
            return PanelSummary(value: formatter.temperature(celsius), caption: fan)
        case .processes:
            guard let processes = engine.processes.value else { return warmup(for: engine.processes) }
            return PanelSummary(value: formatter.count(processes.totalProcessCount),
                                caption: "running")
        case .system:
            guard let system = engine.system.value else { return warmup(for: engine.system) }
            return PanelSummary(value: formatter.uptime(system.uptime), caption: "uptime")
        }
    }

    /// The stand-in while a metric has never sampled: "Collecting…" in the
    /// headline slot itself, so a warming module stays one line instead of
    /// gaining a note underneath that vanishes the moment the number lands.
    /// Harder failures keep their explanation in the detail line.
    private static func warmup<V>(for state: MetricState<V>) -> PanelSummary {
        state.failure == .pending
            ? PanelSummary(value: MetricFailure.pending.shortLabel, emphasis: .state)
            : PanelSummary()
    }

    /// The width the qualifier column needs to hold the widest caption in `summaries`.
    ///
    /// Measured from what is on screen rather than reserved for the longest caption the
    /// panel can ever show: sized for a state that is not always present, the column
    /// stood mostly empty and the whole right edge read as a gap. Every row still
    /// takes the same width, so the numbers keep their shared right edge; that edge
    /// just sits where the captions actually end.
    static func captionColumnWidth(for summaries: [PanelSummary]) -> CGFloat {
        let font = NSFont.systemFont(ofSize: Design.Text.captionSize)
        let widest = summaries.compactMap(\.caption).map {
            ($0 as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return ceil(widest)
    }
}
