import SwiftUI
import AirStatKit

/// One labelled slice of a whole.
public struct CompositionSegment: Equatable, Identifiable {
    public let id: String
    public let label: String
    /// The abbreviation used when the legend has to fit on one line. Defaults to
    /// `label`; supply something shorter for the words that are the reason it does
    /// not fit ("Compressed" is 60pt of a 340pt panel on its own).
    public let shortLabel: String
    /// In whatever unit `StackedCompositionBar`'s format expects — bytes, for both
    /// the memory and disk breakdowns.
    public let value: Double
    public let tint: Color
    /// Free space, purgeable space: real parts of the total, but not *consumption*.
    /// Drawn as track rather than colour so the eye reads the bar as "how much is
    /// taken" without the app having to hide anything.
    public let isRemainder: Bool
    /// Drawn as diagonal stripes of `tint` rather than a solid fill, so one part of a
    /// monochrome bar can stand apart by texture instead of by hue.
    public let isHatched: Bool

    public init(id: String, label: String, shortLabel: String? = nil,
                value: Double, tint: Color, isRemainder: Bool = false, isHatched: Bool = false) {
        self.id = id
        self.label = label
        self.shortLabel = shortLabel ?? label
        self.value = max(0, value)
        self.tint = tint
        self.isRemainder = isRemainder
        self.isHatched = isHatched
    }
}

/// A single horizontal bar split into labelled segments, with a legend beneath.
///
/// Memory (app / wired / compressed / cached / free) and disk (used / purgeable /
/// free) are the same picture: a fixed total, divided. Both get the same component so
/// they read as the same kind of fact.
public struct StackedCompositionBar: View {
    private let segments: [CompositionSegment]
    private let format: ChartValueFormat
    private let barHeight: CGFloat
    private let showsLegend: Bool
    private let accessibilityTitle: String

    @Environment(\.metricFormatter) private var formatter

    public init(_ segments: [CompositionSegment],
                format: ChartValueFormat,
                title: String,
                barHeight: CGFloat = 10,
                showsLegend: Bool = true) {
        self.segments = segments
        self.format = format
        self.accessibilityTitle = title
        self.barHeight = barHeight
        self.showsLegend = showsLegend
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.s) {
            GeometryReader { proxy in
                bar(in: proxy.size)
            }
            .frame(height: barHeight)
            if showsLegend { legend }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityTitle)
        .accessibilityValue(accessibilityValue)
    }

    private var total: Double { segments.reduce(0) { $0 + $1.value } }

    /// One shape per segment rather than one drawing pass; see `PlotShape` for why
    /// this is not a `Canvas`.
    @ViewBuilder
    private func bar(in size: CGSize) -> some View {
        let outline = Path(roundedRect: CGRect(origin: .zero, size: size),
                           cornerRadius: min(Design.Radius.bar, size.height / 2),
                           style: .continuous)
        ZStack {
            PlotShape(outline).fill(Design.Palette.track)
            if total > 0, size.width > 0 {
                ZStack {
                    ForEach(Array(fills(in: size).enumerated()), id: \.offset) { _, fill in
                        PlotShape(fill.path).fill(fill.tint)
                    }
                }
                // Segments are drawn inside the rounded outline rather than as rounded
                // shapes of their own, so the bar reads as one object that has been
                // divided.
                .clipShape(PlotShape(outline))
            }
        }
    }

    private struct Fill {
        let path: Path
        let tint: Color
    }

    private func fills(in size: CGSize) -> [Fill] {
        var result: [Fill] = []
        var x: CGFloat = 0
        for segment in segments {
            let width = CGFloat(segment.value / total) * size.width
            // A segment that exists must be visible. Below a hairline it would round
            // away to nothing, and "0.3 GB of swap" would look identical to none.
            let drawn = segment.value > 0 ? max(width, Design.Space.hairline) : 0
            defer { x += width }
            guard drawn > 0, !segment.isRemainder else { continue }
            let rect = CGRect(x: x, y: 0, width: drawn, height: size.height)
            if segment.isHatched {
                result.append(Fill(path: Path(rect), tint: segment.tint.opacity(CompositionSwatch.hatchBase)))
                result.append(Fill(path: CompositionSwatch.hatch(in: rect), tint: segment.tint))
            } else {
                result.append(Fill(path: Path(rect), tint: segment.tint))
            }
            // A hairline gap keeps two adjacent segments of similar weight apart
            // without needing a border colour that would fight the palette.
            if drawn > Design.Space.xs {
                result.append(Fill(path: Path(CGRect(x: x + drawn - Design.Space.hairline, y: 0,
                                                     width: Design.Space.hairline,
                                                     height: size.height)),
                                   tint: Design.Palette.track))
            }
        }
        return result
    }

    // MARK: Legend

    /// Widest form first: one line with full words, one line with abbreviations, then
    /// two columns over as many rows as it takes.
    ///
    /// The two-column grid costs about 47pt for five segments where a single line costs
    /// 12pt, and in a 340pt panel that difference is the module. So the single line is
    /// tried first and only genuinely gives way when the words will not fit.
    private var legend: some View {
        ViewThatFits(in: .horizontal) {
            inlineLegend(abbreviated: false)
            inlineLegend(abbreviated: true)
            gridLegend
        }
        .accessibilityHidden(true)
    }

    private func inlineLegend(abbreviated: Bool) -> some View {
        HStack(spacing: Design.Space.m) {
            ForEach(segments) { segment in
                entry(segment, abbreviated: abbreviated).fixedSize()
            }
            Spacer(minLength: 0)
        }
    }

    private var gridLegend: some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            ForEach(Array(legendRows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: Design.Space.l) {
                    ForEach(row) { segment in
                        entry(segment, abbreviated: false)
                    }
                    if row.count == 1 { Spacer(minLength: 0) }
                }
            }
        }
    }

    private var legendRows: [[CompositionSegment]] {
        stride(from: 0, to: segments.count, by: 2).map { start in
            Array(segments[start..<min(start + 2, segments.count)])
        }
    }

    private func entry(_ segment: CompositionSegment, abbreviated: Bool) -> some View {
        HStack(spacing: Design.Space.s) {
            CompositionSwatch(segment: segment, side: 6)
            SwiftUI.Text(abbreviated ? segment.shortLabel : segment.label)
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
            SwiftUI.Text(format.string(segment.value, using: formatter))
                .font(Design.Text.micro.monospacedDigit())
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityValue: String {
        guard total > 0 else { return "No data" }
        let parts = segments.map { segment in
            let share = formatter.percent(segment.value / total)
            return "\(segment.label) \(format.string(segment.value, using: formatter)), \(share)"
        }
        return "Total \(format.string(total, using: formatter)). " + parts.joined(separator: ". ")
    }
}

/// A legend key that draws its segment the way the bar does: solid, hatched, or as
/// an outlined patch of track for the remainder.
struct CompositionSwatch: View {
    let segment: CompositionSegment
    let side: CGFloat

    /// The hatched part keeps a faint fill under its stripes, so it still reads as
    /// a part of the bar and not as a gap in it.
    static let hatchBase = 0.22
    private static let pitch: CGFloat = 3
    private static let stripe: CGFloat = 1.25

    /// Diagonal stripes, bottom-left to top-right, clipped to `rect`. Built as filled
    /// parallelograms so it goes through the same fill path as the solid parts.
    static func hatch(in rect: CGRect) -> Path {
        var stripes = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            stripes.addLines([
                CGPoint(x: x, y: rect.maxY),
                CGPoint(x: x + stripe, y: rect.maxY),
                CGPoint(x: x + stripe + rect.height, y: rect.minY),
                CGPoint(x: x + rect.height, y: rect.minY),
            ])
            stripes.closeSubpath()
            x += pitch
        }
        return stripes.intersection(Path(rect))
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 1.5, style: .continuous)
        Group {
            if segment.isRemainder {
                // Filled with the track colour alone it would read as a missing swatch
                // rather than as "this part is empty".
                shape.fill(Design.Palette.track)
                    .overlay { shape.strokeBorder(Design.Palette.separator, lineWidth: Design.Space.hairline) }
            } else if segment.isHatched {
                let rect = CGRect(x: 0, y: 0, width: side, height: side)
                ZStack {
                    PlotShape(Path(rect)).fill(segment.tint.opacity(Self.hatchBase))
                    PlotShape(Self.hatch(in: rect)).fill(segment.tint)
                }
                .clipShape(shape)
            } else {
                shape.fill(segment.tint)
            }
        }
        .frame(width: side, height: side)
    }
}

extension CompositionSegment {
    /// Memory's breakdown as the panel draws it: shades of the label colour for the
    /// parts in use, and free memory last as the remainder.
    public static func memory(_ memory: MemorySnapshot) -> [CompositionSegment] {
        // Monochrome, ordered from what apps hold to what the system gives back on
        // demand. Compressed is the part that grows under pressure, so it alone is
        // hatched: found by texture at a glance, without spending a hue on it.
        let ink = Design.Palette.primaryText
        return [
            CompositionSegment(id: "app", label: "App", value: Double(memory.appBytes),
                               tint: ink),
            CompositionSegment(id: "wired", label: "Wired", value: Double(memory.wiredBytes),
                               tint: ink.opacity(0.62)),
            CompositionSegment(id: "compressed", label: "Compressed", shortLabel: "Comp",
                               value: Double(memory.compressedBytes), tint: ink, isHatched: true),
            CompositionSegment(id: "cached", label: "Cached", value: Double(memory.cachedBytes),
                               tint: ink.opacity(0.4)),
            CompositionSegment(id: "free", label: "Free", value: Double(memory.freeBytes),
                               tint: Design.Palette.track, isRemainder: true),
        ]
    }
}
