import SwiftUI
import AirStatKit

/// A stretch of the day worth remembering: the CPU pinned, memory under pressure, the
/// machine running hot. Read from the day's minute buckets the charts already keep,
/// so finding them costs a walk over three series and no sampling of its own.
struct PanelEvent: Equatable, Identifiable {
    enum Kind: Equatable { case cpu, memory, heat }

    var kind: Kind
    var level: PanelAlertLevel
    var start: Date
    var end: Date
    /// The highest minute mean in the stretch, in the series' own unit.
    var peak: Double
    /// Where the peak sits in the day, 0 at its oldest minute and 1 at now.
    var position: Double
    /// The process named most often across the stretch's minutes.
    var culprit: String?

    var id: Date { start }

    var module: PanelModule {
        switch kind {
        case .cpu: return .cpu
        case .memory: return .memory
        case .heat: return .thermal
        }
    }

    func title(using formatter: MetricFormatter) -> String {
        switch kind {
        case .cpu: return "CPU at \(formatter.percent(peak))"
        case .memory: return "Memory pressure \(formatter.percent(peak))"
        case .heat: return "Running hot, \(formatter.temperature(peak))"
        }
    }
}

enum PanelEvents {
    /// Minute means, not highs: a single busy second is not an event, a minute spent
    /// above the line is. Set above the panel's live thresholds, so the day keeps
    /// only what stood out from an ordinary working day.
    struct Rule {
        let key: SeriesKey
        let kind: PanelEvent.Kind
        let warning: Double
        let critical: Double
        /// The series whose notes name the process behind this one.
        let notes: SeriesKey
    }

    static let rules = [
        Rule(key: .cpuTotal, kind: .cpu, warning: 0.80, critical: 0.95, notes: .cpuTotal),
        Rule(key: .memoryPressure, kind: .memory, warning: 0.70, critical: 0.85, notes: .memoryUsed),
        Rule(key: .cpuTemperature, kind: .heat, warning: 85, critical: 95, notes: .cpuTotal),
    ]

    /// Shorter than this, a stretch is a spike, and the chart already shows those.
    static let minimumMinutes = 2
    /// Minutes below the line that still count as the same stretch.
    static let bridgedMinutes = 2
    /// The day holds more than the card can, so it keeps the newest.
    static let limit = 5

    static func detect(in day: MinuteHistory) -> [PanelEvent] {
        var events: [PanelEvent] = []
        for rule in rules {
            events += detect(series: day.series(rule.key), notes: day.series(rule.notes), rule: rule)
        }
        return Array(events.sorted { $0.start < $1.start }.suffix(limit))
    }

    static func detect(series: MinuteSeries, notes: MinuteSeries, rule: Rule) -> [PanelEvent] {
        let count = series.counts.count
        guard count > 1 else { return [] }
        var events: [PanelEvent] = []
        var run: Range<Int>?
        var quiet = 0

        func date(of index: Int) -> Date {
            series.end.addingTimeInterval(-Double(count - index) * series.bucketDuration)
        }

        func close() {
            guard let range = run, range.count >= minimumMinutes else { return }
            var peakIndex = range.lowerBound
            var names: [String: Int] = [:]
            for i in range where series.counts[i] > 0 {
                if series.averages[i] > series.averages[peakIndex] { peakIndex = i }
                if let name = notes.notes[i] { names[name, default: 0] += 1 }
            }
            let peak = Double(series.averages[peakIndex])
            events.append(PanelEvent(
                kind: rule.kind,
                level: peak >= rule.critical ? .critical : .warning,
                start: date(of: range.lowerBound),
                end: date(of: range.upperBound),
                peak: peak,
                position: Double(peakIndex) / Double(count - 1),
                culprit: names.max { $0.value < $1.value || ($0.value == $1.value && $0.key > $1.key) }?.key))
        }

        for i in 0..<count {
            let above = series.counts[i] > 0 && Double(series.averages[i]) >= rule.warning
            if above {
                run = (run?.lowerBound ?? i)..<(i + 1)
                quiet = 0
            } else if run != nil {
                quiet += 1
                if quiet > bridgedMinutes {
                    close()
                    run = nil
                    quiet = 0
                }
            }
        }
        close()
        return events
    }
}

/// The day at a glance: the CPU's 24 hours with the events pinned on it, and a line
/// per event underneath. Its own card, and one the user can turn off.
struct PanelTodayCard: View {
    let engine: MetricsEngine
    let settings: SettingsStore
    let open: (PanelModule) -> Void

    @Environment(\.metricFormatter) private var formatter

    private static let plotHeight: CGFloat = 52
    private static let pin: CGFloat = 13

    var body: some View {
        let events = PanelEvents.detect(in: engine.dayHistory)
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(alignment: .firstTextBaseline) {
                PanelSectionLabel("CPU, last 24 hours")
                Spacer()
                Text(events.isEmpty ? "Nothing notable" : events.count == 1 ? "1 event" : "\(events.count) events")
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
            if let series = PanelModule.cpu.historySeries {
                HistorySilhouette(series, day: engine.dayHistory,
                                  tint: Design.Palette.secondaryText,
                                  style: settings.settings.charts.style,
                                  height: Self.plotHeight)
                    .overlay(alignment: .topLeading) { pins(events) }
                    .padding(.top, Self.pin / 2)
                axis
            }
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                eventRow(event, number: index + 1)
            }
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.s)
    }

    private func pins(_ events: [PanelEvent]) -> some View {
        GeometryReader { proxy in
            let rect = ChartLayout.plotRect(in: proxy.size)
            ForEach(Array(events.enumerated()), id: \.element.id) { index, event in
                number(index + 1, level: event.level)
                    .position(x: rect.minX + rect.width * CGFloat(event.position), y: 0)
            }
        }
        .accessibilityHidden(true)
    }

    private func number(_ n: Int, level: PanelAlertLevel) -> some View {
        Text("\(n)")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.black.opacity(0.85))
            .frame(width: Self.pin, height: Self.pin)
            .background(Circle().fill(level.color ?? Design.Palette.secondaryText))
    }

    private var axis: some View {
        let labels = HistoryAxis.labels(span: 86_400, end: engine.dayHistory.series(.cpuTotal).end)
        return HStack {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                if index > 0 { Spacer(minLength: 0) }
                Text(label)
                    .font(Design.Text.micro)
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
        }
        .accessibilityHidden(true)
    }

    private func eventRow(_ event: PanelEvent, number n: Int) -> some View {
        Button { open(event.module) } label: {
            HStack(spacing: Design.Space.s) {
                number(n, level: event.level)
                Text(HistoryAxis.clock(event.start))
                    .font(Design.Text.caption.monospacedDigit())
                    .foregroundStyle(Design.Palette.tertiaryText)
                    .frame(width: 38, alignment: .leading)
                Text(event.title(using: formatter))
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: Design.Space.s)
                Text([event.culprit, formatter.duration(event.end.timeIntervalSince(event.start))]
                        .compactMap { $0 }.joined(separator: " · "))
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Opens \(event.module.label)")
    }
}
