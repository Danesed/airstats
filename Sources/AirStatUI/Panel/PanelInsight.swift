import SwiftUI
import AppKit
import AirStatKit

/// How loudly a module's reading should speak. Ordered, so the panel can ask which
/// module is the worst.
enum PanelAlertLevel: Int, Comparable {
    case none, warning, critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    /// Amber before red: a warning is something to keep an eye on, and drawing it in
    /// the colour of a failure is what made a busy panel read as a broken one.
    var color: Color? {
        switch self {
        case .none: return nil
        case .warning: return Color.orange
        case .critical: return Color.red
        }
    }
}

/// The one place the panel decides when a reading is worth colour. The rows, the
/// insight line and the bars all ask here, so they cannot disagree.
@MainActor
enum PanelAlert {
    static func level(for module: PanelModule, engine: MetricsEngine) -> PanelAlertLevel {
        switch module {
        case .cpu:
            guard let cpu = engine.cpu.value else { return .none }
            let busy = cpu.total.busy
            let cores = Double(ProcessInfo.processInfo.activeProcessorCount)
            let highLoad = cpu.loadAverage.one >= cores
            if busy >= 0.90 || (highLoad && busy >= 0.75) { return .critical }
            if busy >= 0.65 || highLoad { return .warning }
        case .memory:
            guard let memory = engine.memory.value else { return .none }
            if memory.memoryPressure == .critical || memory.pressureFraction >= 0.85 { return .critical }
            if memory.memoryPressure == .warning || memory.pressureFraction >= 0.70 { return .warning }
        case .thermal:
            guard let thermal = engine.thermal.value else { return .none }
            let temp = thermal.cpuCelsius ?? 0
            if thermal.pressure == .critical || temp >= 95 { return .critical }
            if thermal.pressure == .serious || temp >= 85 { return .warning }
        case .battery:
            guard let power = engine.power.value, !power.isPluggedIn,
                  let pct = power.percentage else { return .none }
            if pct <= 10 { return .critical }
            if pct <= 20 { return .warning }
        case .disk:
            guard let root = engine.disk.value?.rootVolume, root.totalBytes > 0 else { return .none }
            let free = Double(root.availableBytes) / Double(root.totalBytes)
            if free <= 0.05 { return .critical }
            if free <= 0.10 { return .warning }
        case .gpu:
            guard let gpu = engine.gpu.value?.primary else { return .none }
            let util = gpu.utilization ?? 0
            if util >= 0.95 { return .critical }
            if util >= 0.80 { return .warning }
        case .network, .processes, .system:
            break
        }
        return .none
    }
}

/// The panel's first line: the answer to "why is my Mac slow?", or that nothing is.
///
/// One module speaks, the worst one, and it names what is behind the reading when
/// the process list can say. Nine coloured rows answer the same question only for a
/// reader willing to compare them.
struct PanelInsight: Equatable {
    var level: PanelAlertLevel
    var module: PanelModule?
    var headline: String
    var detail: String?

    /// When two modules are equally loud, the one the user can most often act on
    /// speaks: memory and CPU are usually one app, heat follows them, and a full disk
    /// or a flat battery are the slower stories.
    static let priority: [PanelModule] = [.memory, .cpu, .thermal, .battery, .disk, .gpu]

    @MainActor
    static func make(modules: [PanelModule], engine: MetricsEngine,
                     formatter: MetricFormatter) -> PanelInsight {
        let candidates = priority.filter(modules.contains)
        let worst = candidates.max { a, b in
            let la = PanelAlert.level(for: a, engine: engine)
            let lb = PanelAlert.level(for: b, engine: engine)
            if la != lb { return la < lb }
            // `max` keeps the last of equals, so an earlier priority must compare greater.
            return priority.firstIndex(of: a)! > priority.firstIndex(of: b)!
        }
        guard let module = worst else { return quiet }
        let level = PanelAlert.level(for: module, engine: engine)
        guard level != .none else { return quiet }
        let processes = engine.processes.value?.processes ?? []

        switch module {
        case .cpu:
            let busy = engine.cpu.value.map { formatter.percent($0.total.busy) } ?? ""
            let top = PanelCulprit.top(processes, by: \.cpuPercent)
            return PanelInsight(level: level, module: module, headline: "CPU at \(busy)",
                                detail: top.map { "\($0.name) \(formatter.unclampedPercent($0.value, decimals: 0))" })
        case .memory:
            let pressure = engine.memory.value.map { formatter.percent($0.pressureFraction) } ?? ""
            let top = PanelCulprit.top(processes) { Double($0.memoryBytes) }
            return PanelInsight(level: level, module: module, headline: "Memory pressure \(pressure)",
                                detail: top.map { "\($0.name) \(formatter.memory($0.value))" })
        case .thermal:
            let celsius = engine.thermal.value?.cpuCelsius.map { formatter.temperature($0) }
            let top = PanelCulprit.top(processes, by: \.cpuPercent)
            return PanelInsight(level: level, module: module,
                                headline: celsius.map { "Running hot at \($0)" } ?? "Running hot",
                                detail: top.map { "\($0.name) \(formatter.unclampedPercent($0.value, decimals: 0))" })
        case .battery:
            let power = engine.power.value
            let pct = power?.percentage.map { formatter.percentValue($0) } ?? ""
            return PanelInsight(level: level, module: module, headline: "Battery at \(pct)",
                                detail: power?.timeToEmpty.map { formatter.duration($0) + " left" })
        case .disk:
            let free = engine.disk.value?.rootVolume.map { formatter.storage($0.availableBytes) }
            return PanelInsight(level: level, module: module, headline: "Startup disk almost full",
                                detail: free.map { "\($0) free" })
        case .gpu:
            let util = engine.gpu.value?.primary?.utilization.map { formatter.percent($0) } ?? ""
            return PanelInsight(level: level, module: module, headline: "GPU at \(util)", detail: nil)
        case .network, .processes, .system:
            return quiet
        }
    }

    static let quiet = PanelInsight(level: .none, module: nil,
                                    headline: "Everything looks normal", detail: nil)
}

/// The app behind a reading, with its helpers counted in.
///
/// Chrome at 4 GB is twenty processes at 200 MB, and none of them would top a list on
/// its own. Everything inside one `.app` is summed under the app's name; a plain
/// executable stands for itself.
enum PanelCulprit {
    struct Entry: Equatable {
        var name: String
        var value: Double
    }

    static func top(_ processes: [ProcessRow], by value: (ProcessRow) -> Double) -> Entry? {
        var totals: [String: Entry] = [:]
        for process in processes {
            let amount = value(process)
            guard amount > 0 else { continue }
            let key = appName(for: process)
            totals[key, default: Entry(name: key, value: 0)].value += amount
        }
        return totals.values.max { $0.value < $1.value || ($0.value == $1.value && $0.name > $1.name) }
    }

    static func top(_ processes: [ProcessRow], by keyPath: KeyPath<ProcessRow, Double>) -> Entry? {
        top(processes) { $0[keyPath: keyPath] }
    }

    /// "Google Chrome" for anything under `/Applications/Google Chrome.app/`.
    static func appName(for process: ProcessRow) -> String {
        guard let path = process.executablePath, let range = path.range(of: ".app/") else {
            return process.name
        }
        let bundle = path[path.startIndex..<range.lowerBound]
        return bundle.split(separator: "/").last.map(String.init) ?? process.name
    }
}

/// The insight as a row. Clicking it opens the module it is about.
struct PanelInsightRow: View {
    let insight: PanelInsight
    let open: (PanelModule) -> Void

    @State private var isHovering = false

    var body: some View {
        Button {
            if let module = insight.module { open(module) }
        } label: {
            HStack(spacing: Design.Space.s) {
                Circle()
                    .fill(insight.level.color ?? Color.green)
                    .frame(width: Design.Space.s, height: Design.Space.s)
                Text(insight.headline)
                    .font(Design.Text.label.weight(.medium))
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: Design.Space.s)
                if let detail = insight.detail {
                    Text(detail)
                        .font(Design.Text.caption.monospacedDigit())
                        .foregroundStyle(Design.Palette.secondaryText)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .padding(.horizontal, Design.Space.panelInset)
            .padding(.vertical, Design.Space.s)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                    .fill(isHovering && insight.module != nil ? Design.Palette.track : .clear)
                    .padding(.horizontal, Design.Space.s)
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel([insight.headline, insight.detail].compactMap { $0 }.joined(separator: ", "))
        .accessibilityHint(insight.module == nil ? "" : "Opens \(insight.module!.label)")
    }
}
