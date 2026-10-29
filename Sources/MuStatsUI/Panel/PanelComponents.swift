import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MuStatsKit

// MARK: - Core strip

/// A core cluster shaped like a `PanelBarRow`: what it is, the cores, how busy they
/// are.
///
/// Wraps `CoreGrid` rather than drawing bars, but keeps the cluster on one line with
/// its own aggregate percentage — the panel cannot spend a second line on cluster
/// captions, and "the P-cores are pinned" is a claim that wants a number next to it.
struct PanelCoreRow: View {
    let label: String
    let loads: [CPULoad]
    let busy: Double?
    let tint: Color
    var slotWidth: CGFloat = PanelCoreRow.preferredSlotWidth
    var labelWidth: CGFloat = PanelCoreRow.defaultLabelWidth
    /// Room held for the strip, the widest cluster's, so the value after a shorter
    /// cluster still lines up with the one after the longer.
    var stripWidth: CGFloat?

    @Environment(\.metricFormatter) private var formatter

    /// Vertical range for the fill, and the whole reason a core bar means anything.
    ///
    /// Measured, not guessed: rendering cores at exactly 25/50/75/100% at 12, 16, 20
    /// and 24pt, the 75% and 100% cells are not reliably separable below 20 at 1x. A
    /// shorter strip saves a few points of panel and gives up the magnitude it was
    /// drawn to convey.
    ///
    /// 16 now that the cells are narrow columns rather than squares: a column reads
    /// its fill against its own height, and the strip gives back a third of its
    /// height to the panel.
    private static let stripHeight: CGFloat = 16

    /// Slot width, fixed rather than filling the row.
    ///
    /// `CoreGrid` divides whatever frame it gets among its cores, so a six-core row and
    /// a five-core row sharing the same width would draw noticeably different bar
    /// widths. Pinning the slot keeps a core the same size in both rows and lets the
    /// six-core strip run visibly longer, which is the truth about the machine.
    ///
    /// Preferred, not absolute. Ten P-cores at 28pt want 280pt of strip in a row that
    /// has about 206pt to give once the label, the gaps and the value are out, and a
    /// 24-core Ultra wants 672. Past that point the strip pushed every row in the
    /// panel out through both sides of the window. `slotWidth(sharedAcross:)` shrinks
    /// the slot until the widest cluster fits, and the caller hands the same answer to
    /// every row so the two clusters still draw their cores at one size.
    ///
    /// 9, for columns about 6pt wide with a gap between, the way Activity Monitor
    /// draws its cores. At 28 every cell was a square, and two rows of squares were
    /// the heaviest shape in the panel.
    static let preferredSlotWidth: CGFloat = 9

    /// Wider than the detail rows' 58pt column by the width of a second digit: an
    /// Ultra's "24 P-cores" was the one label in the panel that truncated.
    static let defaultLabelWidth: CGFloat = 64

    /// Width held for the value column so the strip budget is honest at "100%".
    private static let valueReserve: CGFloat = 36

    /// What is left for the strip once the label, the value, the stack's three gaps
    /// and the spacer's minimum are taken out of the panel's content width.
    private static var stripBudget: CGFloat {
        CGFloat(PanelSettings.width) - 2 * Design.Space.panelInset
            - defaultLabelWidth - 4 * Design.Space.m - valueReserve
    }

    /// Label width when the two clusters share one line: "10 P-cores" and no more.
    static let compactLabelWidth: CGFloat = 54

    /// Whether two clusters of up to `widestCluster` cores fit side by side at the
    /// preferred slot, each in half the content width.
    static func fitsSideBySide(widestCluster: Int) -> Bool {
        let half = (CGFloat(PanelSettings.width) - 2 * Design.Space.panelInset - Design.Space.xl) / 2
        let needed = compactLabelWidth + 2 * Design.Space.m + valueReserve
            + CGFloat(widestCluster) * preferredSlotWidth
        return needed <= half
    }

    /// The slot every core row should use when the widest of them has `widestCluster`
    /// cores: the preferred width, or the largest that fits.
    static func slotWidth(sharedAcross widestCluster: Int) -> CGFloat {
        guard widestCluster > 0 else { return preferredSlotWidth }
        return min(preferredSlotWidth, stripBudget / CGFloat(widestCluster))
    }

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Text(label)
                .font(Design.Text.label)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
                .frame(width: labelWidth, alignment: .leading)
            CoreGrid(cores: loads, tint: tint, height: Self.stripHeight,
                     showsClusterLabels: false)
                .frame(width: CGFloat(loads.count) * slotWidth)
                .frame(width: max(stripWidth ?? 0, CGFloat(loads.count) * slotWidth), alignment: .leading)
            Text(busy.map { formatter.percent($0) } ?? MetricFormatter.unavailable)
                .font(Design.Text.value)
                .foregroundStyle(Design.Palette.primaryText)
                .fixedSize()
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(loads.count) \(label)")
        .accessibilityValue(busy.map { formatter.percent($0) } ?? "")
    }
}

// MARK: - Composition bar

/// Legend for a composition bar, on the panel's two-column grid.
///
/// Four segments on one line only fit at 9pt, which is below the size a number should
/// ever be set at when the user is expected to read it. At 10pt they need two rows —
/// and on the same column rhythm as `PanelDetailGrid`, so the legend lines up with the
/// readouts under it instead of forming a third alignment.
///
/// The remainder segment is deliberately absent: it is drawn as bare track, and "the
/// empty part of the bar is the empty part" needs no swatch to explain it.
struct PanelSegmentLegend: View {
    let segments: [CompositionSegment]
    let format: ChartValueFormat

    @Environment(\.metricFormatter) private var formatter

    var body: some View {
        Grid(alignment: .leading,
             horizontalSpacing: Design.Space.xl,
             verticalSpacing: Design.Space.xxs) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { segment in
                        entry(segment).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    if row.count == 1 { Color.clear.frame(height: 0) }
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func entry(_ segment: CompositionSegment) -> some View {
        HStack(spacing: Design.Space.xs) {
            CompositionSwatch(segment: segment, side: Design.Space.s)
            Text(localizing: segment.shortLabel)
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.secondaryText)
            Spacer(minLength: Design.Space.xs)
            Text(format.string(segment.value, using: formatter))
                .font(Design.Text.caption.monospacedDigit())
                .foregroundStyle(Design.Palette.primaryText)
        }
        .lineLimit(1)
    }

    private var visible: [CompositionSegment] { segments.filter { !$0.isRemainder } }

    private var rows: [[CompositionSegment]] {
        stride(from: 0, to: visible.count, by: 2).map { start in
            Array(visible[start..<min(start + 2, visible.count)])
        }
    }
}

// MARK: - Bar row

/// A readout whose value has a real maximum, with the bar inline rather than on its
/// own line — the panel cannot afford a second line for every gauge.
struct PanelBarRow: View {
    let label: String
    let value: String
    let fraction: Double
    let tint: Color
    /// Fixed so the bars of consecutive rows start at the same x and read as a column.
    var labelWidth: CGFloat = 58

    var body: some View {
        HStack(spacing: Design.Space.m) {
            Text(localizing: label)
                .font(Design.Text.label)
                .foregroundStyle(Design.Palette.secondaryText)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: labelWidth, alignment: .leading)
            CapacityBar(fraction: fraction, tint: tint)
            Text(value)
                .font(Design.Text.value)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

// MARK: - Detail grid

struct PanelDetailEntry: Identifiable, Equatable {
    var id: String { label }
    var label: String
    var value: String

    init(_ label: String, _ value: String) {
        self.label = label
        self.value = value
    }
}

/// Supporting detail as small tiles, three to a row: the label over the value.
///
/// A label and a value side by side in half the panel left both ends of every row
/// apart, and four of them read as a form. Stacked in a tile, each figure is one
/// object the eye picks up at once, and a row of three costs no more height.
struct PanelDetailGrid: View {
    let entries: [PanelDetailEntry]

    /// Three to a row, or four when there are exactly four: three and one left a
    /// lone tile under a full row.
    private var columns: Int { entries.count == 4 ? 4 : 3 }

    var body: some View {
        Grid(alignment: .leading,
             horizontalSpacing: Design.Space.s,
             verticalSpacing: Design.Space.s) {
            ForEach(rows, id: \.first?.id) { row in
                GridRow {
                    ForEach(row) { entry in
                        tile(entry)
                    }
                    // Keeps the last row's tiles the width of the rows above.
                    ForEach(row.count..<columns, id: \.self) { _ in
                        Color.clear.frame(height: 0)
                    }
                }
            }
        }
    }

    private func tile(_ entry: PanelDetailEntry) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(localizing: entry.label)
                .font(Design.Text.micro.weight(.medium))
                .foregroundStyle(Design.Palette.tertiaryText)
                .textCase(.uppercase)
                .lineLimit(1)
            UnitText.text(entry.value, size: 13, weight: .semibold)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.xs)
        .background(RoundedRectangle(cornerRadius: Design.Radius.control + 1, style: .continuous)
            .fill(Design.Palette.cardFill))
        .accessibilityElement(children: .combine)
    }

    private var rows: [[PanelDetailEntry]] {
        stride(from: 0, to: entries.count, by: columns).map { start in
            Array(entries[start..<min(start + columns, entries.count)])
        }
    }
}

// MARK: - Process icons

/// What to draw beside a process name.
enum PanelProcessIcon {
    case bundle(NSImage)
    /// No bundle to take an icon from — most processes, since launchd, logd and
    /// WindowServer are plain executables.
    case executable
}

/// Icons for the process list.
///
/// Every row resolves to something, so the list has one left edge. Half the rows
/// carrying an icon and half not is worse than either choice made consistently.
///
/// `NSWorkspace.icon(forFile:)` stats the bundle, so it is resolved once per
/// executable path and never again — including the misses, so a daemon does not
/// re-hit the filesystem every time the panel redraws.
@MainActor
enum PanelAppIcon {
    private static var cache: [String: PanelProcessIcon] = [:]

    /// The cache is keyed by executable path, and the set of paths a long session sees
    /// is not the set of apps installed: every build tool, helper and short-lived daemon
    /// that ever reached the top of the process list adds one and nothing ever took one
    /// away. 224 icons measured at 3.1 MB of dirty heap, so an uncapped cache is real
    /// growth over a day of uptime. Flushed wholesale rather than evicted one at a time —
    /// the next panel redraw re-resolves only the dozen rows it actually shows, and that
    /// is cheaper than tracking use counts for the life of the process.
    private static let cacheLimit = 512

    static func icon(for process: ProcessRow) -> PanelProcessIcon {
        guard let key = process.executablePath ?? process.bundleIdentifier else { return .executable }
        if let cached = cache[key] { return cached }
        if cache.count >= cacheLimit { cache.removeAll(keepingCapacity: true) }
        let resolved: PanelProcessIcon
        if let path = process.executablePath, let bundle = bundlePath(for: path),
           FileManager.default.fileExists(atPath: bundle) {
            resolved = .bundle(NSWorkspace.shared.icon(forFile: bundle))
        } else if let app = appURL(forBundleIdentifier: process.bundleIdentifier) {
            resolved = .bundle(NSWorkspace.shared.icon(forFile: app.path))
        } else {
            resolved = .executable
        }
        cache[key] = resolved
        return resolved
    }

    /// The app a helper's bundle identifier belongs to, trying it and then each
    /// shorter prefix: "com.google.Chrome.helper.renderer" finds "com.google.Chrome".
    /// Stops at two components, below which a prefix names a vendor, not an app.
    private static func appURL(forBundleIdentifier identifier: String?) -> URL? {
        guard var parts = identifier?.split(separator: ".").map(String.init) else { return nil }
        while parts.count >= 3 {
            if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: parts.joined(separator: ".")) {
                return url
            }
            parts.removeLast()
        }
        return nil
    }

    /// The enclosing app bundle: "/Applications/Claude.app/Contents/Frameworks/Claude"
    /// → "/Applications/Claude.app".
    ///
    /// A running process's executable is almost never the bundle itself — it lives
    /// several directories inside one — so testing the path for a ".app" suffix
    /// resolves nothing on a real machine. Taking the first ".app" component also gets
    /// helpers right: Safari's XPC services correctly show Safari's icon.
    private static func bundlePath(for path: String) -> String? {
        guard let range = path.range(of: ".app/") else {
            return path.hasSuffix(".app") ? path : nil
        }
        return String(path[path.startIndex..<range.lowerBound]) + ".app"
    }
}

// MARK: - Copyable Readout Row

struct CopyableReadoutRow: View {
    let label: String
    let value: String
    /// Set quieter beside the value and left out of what is copied: the router's
    /// round trip beside its address.
    let detail: String?
    @State private var isCopied = false

    init(_ label: String, _ value: String, detail: String? = nil) {
        self.label = label
        self.value = value
        self.detail = detail
    }

    var body: some View {
        Button(action: copyToClipboard) {
            HStack(spacing: Design.Space.rowGap) {
                Text(localizing: label)
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Design.Space.m)
                HStack(spacing: Design.Space.xs) {
                    if isCopied {
                        Image(systemName: "checkmark")
                            .font(Design.Text.micro)
                            .foregroundStyle(Color.green)
                        Text("Copied")
                            .font(Design.Text.caption)
                            .foregroundStyle(Color.green)
                    } else {
                        if let detail {
                            Text(detail)
                                .font(Design.Text.caption.monospacedDigit())
                                .foregroundStyle(Design.Palette.secondaryText)
                                .lineLimit(1)
                        }
                        Text(value)
                            .font(Design.Text.value)
                            .foregroundStyle(Design.Palette.primaryText)
                            .lineLimit(1)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label), \(value)")
        .accessibilityHint("Click to copy")
    }

    private func copyToClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(value, forType: .string)
        withAnimation(.easeInOut(duration: 0.15)) { isCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
            withAnimation(.easeInOut(duration: 0.15)) { isCopied = false }
        }
    }
}

// MARK: - Row sparkline

/// The recent history of a summary row's value, small enough to sit beside its name.
///
/// No axis and no labels: the number beside it is the reading, and this only says
/// whether it got there by climbing, falling or holding. One stroke and one faint
/// fill from the samples the engine already keeps, rebuilt with the row.
struct PanelSparkline: View {
    let samples: SampleRing
    let key: SeriesKey
    var domain: ClosedRange<Double>?
    let tint: Color

    static let width: CGFloat = 40
    static let height: CGFloat = 12

    var body: some View {
        GeometryReader { proxy in
            let paths = Self.paths(samples, key: key, domain: domain, in: proxy.size)
            ZStack {
                PlotShape(paths.area).fill(tint.opacity(0.14))
                PlotShape(paths.line)
                    .stroke(tint, style: StrokeStyle(lineWidth: 1, lineCap: .round, lineJoin: .round))
            }
        }
        .accessibilityHidden(true)
    }

    /// At most one sample per half point of width, the newest at the right edge.
    static func paths(_ samples: SampleRing, key: SeriesKey, domain: ClosedRange<Double>?,
                      in size: CGSize) -> (line: Path, area: Path) {
        var line = Path()
        var area = Path()
        let count = samples.count
        guard count >= Design.Chart.minimumPoints, size.width > 1, size.height > 1 else {
            return (line, area)
        }
        let stats = ChartStats(samples)
        let scale = ChartScale.resolve(peak: stats.maximum, domain: domain,
                                       naturalUpperBound: key.naturalUpperBound, adaptive: true)
        let points = min(count, max(Int(size.width * 2), 2))
        let inset: CGFloat = 1
        let height = size.height - 2 * inset
        var first = CGPoint.zero
        var last = CGPoint.zero
        for i in 0..<points {
            let index = count - points + i
            let value = Double(samples[index])
            let fraction = min(max((value - scale.lowerBound) / scale.span, 0), 1)
            let point = CGPoint(x: size.width * CGFloat(i) / CGFloat(points - 1),
                                y: inset + height * (1 - CGFloat(fraction)))
            if i == 0 { line.move(to: point); first = point } else { line.addLine(to: point) }
            last = point
        }
        area.addPath(line)
        area.addLine(to: CGPoint(x: last.x, y: size.height))
        area.addLine(to: CGPoint(x: first.x, y: size.height))
        area.closeSubpath()
        return (line, area)
    }
}

// MARK: - Section label

/// The heading of a group inside an open module: "Using the most CPU", "Devices".
/// One style for all of them, so a module's groups read as groups.
struct PanelSectionLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        Text(localizing: title)
            .font(Design.Text.caption.weight(.medium))
            .foregroundStyle(Design.Palette.tertiaryText)
            .textCase(.uppercase)
            .kerning(0.3)
            .lineLimit(1)
            .padding(.bottom, Design.Space.xxs)
            .accessibilityAddTraits(.isHeader)
    }
}
