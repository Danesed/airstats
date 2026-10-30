import SwiftUI
import MuStatsKit

/// The live chip: a drawing of the processor whose blocks light with their real load.
///
/// An extra, off by default. Nothing here samples: it draws the snapshot the panel
/// already holds, and only while its tab is the one on screen.
///
/// The floorplan is a schematic, not a die shot: performance cores, efficiency cores,
/// the GPU and the memory, laid out the way the readings group them. Each core is
/// its own cell, lit by its own busy fraction; the GPU has one utilisation, so its
/// cores light together.
struct PanelLiveChip: View {
    let engine: MetricsEngine

    @Environment(\.metricFormatter) private var formatter

    private static let teal = Color(red: 0.42, green: 0.93, blue: 0.80)
    private static let blue = Color(red: 0.20, green: 0.52, blue: 0.86)

    var body: some View {
        let cpu = engine.cpu.value
        let gpu = engine.gpu.value?.primary
        let memory = engine.memory.value
        VStack(alignment: .leading, spacing: Design.Space.s) {
            HStack(alignment: .firstTextBaseline) {
                PanelSectionLabel(engine.system.value?.chipName ?? String(localized: "This Mac's chip"))
                Spacer()
                if let cpu {
                    Text(verbatim: "CPU \(formatter.percent(cpu.total.busy))")
                        .font(Design.Text.caption.monospacedDigit())
                        .foregroundStyle(Design.Palette.secondaryText)
                }
            }
            die(cpu: cpu, gpu: gpu, memory: memory)
                .frame(height: 248)
            legend
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.vertical, Design.Space.s)
    }

    // MARK: Die

    private func die(cpu: CPUSnapshot?, gpu: GPUDevice?, memory: MemorySnapshot?) -> some View {
        let cores = Self.cores(cpu)
        return HStack(spacing: 8) {
            VStack(spacing: 8) {
                cluster("P-cores", loads: cores.performance, maxCell: 28)
                // A Mac with one kind of core (Intel) has no efficiency cluster to draw.
                if !cores.efficiency.isEmpty {
                    cluster("E-cores", loads: cores.efficiency, maxCell: 18)
                }
            }
            VStack(spacing: 8) {
                gpuBlock(gpu)
                memoryBlock(memory)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(LinearGradient(colors: [Color(white: 0.06), Color(white: 0.02)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(LinearGradient(colors: [Self.teal.opacity(0.7), Self.blue.opacity(0.25)],
                                             startPoint: .bottomLeading, endPoint: .topTrailing),
                              lineWidth: 1)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary(cpu: cpu, gpu: gpu, memory: memory))
    }

    private func cluster(_ title: String, loads: [Double], maxCell: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            blockTitle(title, loads.isEmpty ? nil : formatter.percent(loads.reduce(0, +) / Double(loads.count)))
            // Sized to the block, so four cores draw large and an Ultra's twenty-four
            // still fit, smaller, without being cut off.
            GeometryReader { proxy in
                let fit = Self.fit(count: loads.count, in: proxy.size, gap: 4, maxCell: maxCell)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(fit.cell), spacing: 4), count: fit.columns),
                          alignment: .leading, spacing: 4) {
                    ForEach(Array(loads.enumerated()), id: \.offset) { _, load in
                        coreCell(load: load, size: fit.cell)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(blockBackground)
    }

    private func gpuBlock(_ gpu: GPUDevice?) -> some View {
        let load = gpu?.utilization ?? 0
        // Every core the GPU reports, up to an Ultra's eighty; ten where it reports none.
        let count = min(max(gpu?.coreCount ?? 10, 1), 80)
        return VStack(alignment: .leading, spacing: 5) {
            blockTitle("GPU", gpu?.utilization.map { formatter.percent($0) })
            GeometryReader { proxy in
                let fit = Self.fit(count: count, in: proxy.size, gap: 3, maxCell: 14)
                LazyVGrid(columns: Array(repeating: GridItem(.fixed(fit.cell), spacing: 3), count: fit.columns),
                          alignment: .leading, spacing: 3) {
                    ForEach(0..<count, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: fit.cell > 8 ? 2 : 1, style: .continuous)
                            .fill(Self.teal.opacity(0.12 + 0.88 * load))
                            .frame(width: fit.cell, height: fit.cell)
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(blockBackground)
    }

    private func memoryBlock(_ memory: MemorySnapshot?) -> some View {
        let used = memory?.usedFraction ?? 0
        let pressure = memory?.pressureFraction ?? 0
        let tint = pressure >= 0.85 ? Color.red : (pressure >= 0.7 ? Color.orange : Self.blue)
        return VStack(alignment: .leading, spacing: 5) {
            blockTitle("Memory", memory.map { formatter.percent($0.usedFraction) })
            HStack(spacing: 5) {
                ForEach(0..<4, id: \.self) { index in
                    // Four packages filling in turn, the way the bar fills left to right.
                    let share = min(max(used * 4 - Double(index), 0), 1)
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.white.opacity(0.06))
                        .overlay(alignment: .bottom) {
                            GeometryReader { proxy in
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .fill(tint.opacity(0.85))
                                    .frame(height: proxy.size.height * share)
                                    .frame(maxHeight: .infinity, alignment: .bottom)
                            }
                        }
                }
            }
            .frame(maxHeight: .infinity)
        }
        .padding(8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(blockBackground)
    }

    private func coreCell(load: Double, size: CGFloat) -> some View {
        RoundedRectangle(cornerRadius: size > 20 ? 5 : 3, style: .continuous)
            .fill(Self.teal.opacity(0.10 + 0.90 * load))
            .overlay(
                RoundedRectangle(cornerRadius: size > 20 ? 5 : 3, style: .continuous)
                    .strokeBorder(Self.teal.opacity(0.35), lineWidth: 0.5)
            )
            .frame(width: size, height: size)
            .animation(.easeOut(duration: 0.6), value: load)
    }

    private func blockTitle(_ title: String, _ value: String?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            Text(String(localized: String.LocalizationValue(title)).uppercased())
                .font(.system(size: 9, weight: .semibold))
                .kerning(0.4)
                .foregroundStyle(Self.teal.opacity(0.8))
            if let value {
                Text(value)
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.white.opacity(0.6))
            }
        }
    }

    private var blockBackground: some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .strokeBorder(Self.teal.opacity(0.22), lineWidth: 0.75)
    }

    private var legend: some View {
        HStack(spacing: Design.Space.s) {
            RoundedRectangle(cornerRadius: 2).fill(Self.teal.opacity(0.12)).frame(width: 10, height: 10)
            Text("idle")
            RoundedRectangle(cornerRadius: 2).fill(Self.teal).frame(width: 10, height: 10)
            Text("busy")
            Spacer()
        }
        .font(Design.Text.caption)
        .foregroundStyle(Design.Palette.tertiaryText)
    }

    // MARK: Data

    /// The largest square cell, up to `maxCell`, at which `count` cells fit in `size`,
    /// and the columns that gives. Tried for every column count, so four cores come
    /// out as a large two-by-two and twenty-four as a tighter grid of small ones.
    static func fit(count: Int, in size: CGSize, gap: CGFloat, maxCell: CGFloat) -> (columns: Int, cell: CGFloat) {
        guard count > 0, size.width > 0, size.height > 0 else { return (1, 0) }
        var best = (columns: 1, cell: CGFloat(0))
        for columns in 1...count {
            let rows = (count + columns - 1) / columns
            let byWidth = (size.width - CGFloat(columns - 1) * gap) / CGFloat(columns)
            let byHeight = (size.height - CGFloat(rows - 1) * gap) / CGFloat(rows)
            let cell = min(byWidth, byHeight, maxCell).rounded(.down)
            if cell > best.cell { best = (columns, cell) }
        }
        return best
    }

    /// Per-core busy fractions split by kind. A Mac that does not report kinds puts
    /// every core in the performance cluster.
    static func cores(_ cpu: CPUSnapshot?) -> (performance: [Double], efficiency: [Double]) {
        guard let cpu else { return ([], []) }
        var performance: [Double] = []
        var efficiency: [Double] = []
        for (index, core) in cpu.perCore.enumerated() {
            let kind = index < cpu.coreKinds.count ? cpu.coreKinds[index] : .unknown
            if kind == .efficiency { efficiency.append(core.busy) } else { performance.append(core.busy) }
        }
        return (performance, efficiency)
    }

    private func accessibilitySummary(cpu: CPUSnapshot?, gpu: GPUDevice?, memory: MemorySnapshot?) -> String {
        var parts: [String] = []
        if let cpu { parts.append("CPU \(formatter.percent(cpu.total.busy))") }
        if let utilization = gpu?.utilization { parts.append("GPU \(formatter.percent(utilization))") }
        if let memory { parts.append("memory \(formatter.percent(memory.usedFraction))") }
        return "Live chip: " + parts.joined(separator: ", ")
    }
}
