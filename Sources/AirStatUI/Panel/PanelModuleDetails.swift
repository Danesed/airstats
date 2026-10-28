import SwiftUI
import Darwin
import AirStatKit

/// The second-look content of every module.
///
/// Split from `PanelModuleView` so the module shell — header, disclosure, hover,
/// accessibility — stays readable next to nine bodies of metric-specific layout.
extension PanelModuleView {

    @ViewBuilder
    var detail: some View {
        switch module {
        case .cpu:       cpuDetail
        case .memory:    memoryDetail
        case .gpu:       gpuDetail
        case .network:   networkDetail
        case .disk:      diskDetail
        case .battery:   batteryDetail
        case .thermal:   thermalDetail
        case .processes: processesDetail
        case .system:    systemDetail
        }
    }

    /// The history chart under a module's rows, when the module has a series and the
    /// user has not switched the charts off.
    ///
    /// Under the rows rather than over them: the rows are what the module is for, and
    /// the chart is the same headline value the header already shows, spread over
    /// time. `available` lets a module withhold the chart when the series behind it
    /// cannot exist on this machine, a battery chart on a desktop being the case.
    @ViewBuilder
    func history(available: Bool = true) -> some View {
        if available, settings.settings.panel.showsHistoryChart,
           let series = module.historySeries {
            HistoryChart(series,
                         history: engine.history,
                         day: engine.dayHistory,
                         month: engine.monthHistory,
                         settings: settings.settings.charts,
                         tint: chartTint,
                         band: bandTint,
                         defaultRange: settings.settings.panel.defaultHistoryRange,
                         range: $historyRange)

                .padding(.top, Design.Space.s)
        }
    }

    /// Detail when the module is open, and the reason when the metric is unavailable.
    ///
    /// A failure is shown whether or not the module is collapsed: for a module that
    /// has no value, the explanation *is* the summary, and hiding it would leave a
    /// header with a blank space where the number belongs.
    @ViewBuilder
    private func section<V: Sendable & Equatable, C: View>(
        _ state: MetricState<V>,
        @ViewBuilder content: @escaping (V) -> C
    ) -> some View {
        if isExpanded {
            // The transition lives here, on the view that is actually inserted and
            // removed. On the container in `PanelModuleView` it applied to nothing.
            MetricContent(state) { content($0) }
                .transition(.disclosure)
        } else if let failure = state.failure, failure != .pending {
            // Pending is the one failure that does not get a note of its own: the
            // header is already saying "Collecting…" where the number will land,
            // and a second line underneath it is the reflow this costs a module.
            UnavailableNote(failure)
        }
    }

    // MARK: CPU

    private var cpuDetail: some View {
        section(engine.cpu) { cpu in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                coreClusters(cpu)
                culprits("Using the most CPU", by: { $0.cpuPercent }) {
                    formatter.unclampedPercent($0.cpuPercent)
                }
                PanelDetailGrid(entries: [
                    // The 1-minute load is already in the header caption; the grid
                    // adds the two slower averages instead of repeating it.
                    PanelDetailEntry("Load 5m", formatter.fixed(cpu.loadAverage.five, decimals: 1)),
                    PanelDetailEntry("Load 15m", formatter.fixed(cpu.loadAverage.fifteen, decimals: 1)),
                    PanelDetailEntry("Threads", formatter.count(cpu.threadCount)),
                ])
                history()
            }
        }
    }

    @ViewBuilder
    private func coreClusters(_ cpu: CPUSnapshot) -> some View {
        let efficiency = cores(cpu, of: .efficiency)
        let performance = cores(cpu, of: .performance)
        if efficiency.isEmpty || performance.isEmpty {
            if !cpu.perCore.isEmpty {
                PanelCoreRow(label: "\(cpu.perCore.count) cores", loads: cpu.perCore,
                             busy: cpu.total.busy, tint: tint,
                             slotWidth: PanelCoreRow.slotWidth(sharedAcross: cpu.perCore.count))
            }
        } else if PanelCoreRow.fitsSideBySide(widestCluster: max(efficiency.count, performance.count)) {
            // One line for both clusters while they fit: the strip is the shape of
            // the machine, and a second row added height without adding a reading.
            HStack(spacing: Design.Space.xl) {
                PanelCoreRow(label: "\(efficiency.count) E-cores", loads: efficiency,
                             busy: cpu.efficiencyBusy, tint: tint,
                             labelWidth: PanelCoreRow.compactLabelWidth)
                PanelCoreRow(label: "\(performance.count) P-cores", loads: performance,
                             busy: cpu.performanceBusy, tint: tint,
                             labelWidth: PanelCoreRow.compactLabelWidth)
            }
        } else {
            let widest = max(efficiency.count, performance.count)
            let slot = PanelCoreRow.slotWidth(sharedAcross: widest)
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                PanelCoreRow(label: "\(efficiency.count) E-cores", loads: efficiency,
                             busy: cpu.efficiencyBusy, tint: tint, slotWidth: slot,
                             stripWidth: CGFloat(widest) * slot)
                PanelCoreRow(label: "\(performance.count) P-cores", loads: performance,
                             busy: cpu.performanceBusy, tint: tint, slotWidth: slot,
                             stripWidth: CGFloat(widest) * slot)
            }
        }
    }

    private func cores(_ cpu: CPUSnapshot, of kind: CoreKind) -> [CPULoad] {
        guard cpu.coreKinds.count == cpu.perCore.count else { return [] }
        return zip(cpu.perCore, cpu.coreKinds).compactMap { $0.1 == kind ? $0.0 : nil }
    }

    // MARK: Memory

    private var memoryDetail: some View {
        section(engine.memory) { memory in
            let segments = Self.readableSegments(CompositionSegment.memory(memory))
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                StackedCompositionBar(segments, format: .memoryBytes,
                                      title: "Memory composition",
                                      barHeight: Design.Space.s, showsLegend: false)
                PanelSegmentLegend(segments: segments, format: .memoryBytes)
                culprits("Using the most memory", by: { Double($0.memoryBytes) }) {
                    formatter.memory($0.memoryBytes)
                }
                PanelBarRow(label: "Pressure",
                            value: "\(memory.memoryPressure.label) (\(formatter.percent(memory.pressureFraction)))",
                            fraction: memory.pressureFraction,
                            tint: tint)
                PanelDetailGrid(entries: [
                    PanelDetailEntry("Used", formatter.memory(memory.usedBytes)),
                    PanelDetailEntry("Free", formatter.memory(memory.freeBytes)),
                    PanelDetailEntry("Swap", formatter.memory(memory.swapUsedBytes)),
                    PanelDetailEntry("Total", formatter.memory(memory.totalBytes)),
                ])
                history()
            }
        }
    }

    /// The processes leading on one resource, under a label that says which.
    ///
    /// The question an open module raises is "what is doing this", so each module that
    /// can answer it does, from the process list the panel already samples: three rows,
    /// and none at all when nothing is using the resource, so an idle disk does not
    /// list three processes at 0 B/s.
    @ViewBuilder
    func culprits(_ title: String, count: Int = 3,
                  by measure: @escaping (ProcessRow) -> Double,
                  value: @escaping (ProcessRow) -> String) -> some View {
        if let processes = engine.processes.value {
            let ranked = processes.processes
                .filter { measure($0) > 0 }
                .sorted { measure($0) > measure($1) }
                .prefix(count)
            if !ranked.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    PanelSectionLabel(title)
                    ForEach(Array(ranked)) { process in
                        processRow(process, value: value(process))
                    }
                }
                .padding(.top, Design.Space.xs)
            }
        }
    }

    /// Composition shades, re-tinted so every segment can actually be read.
    ///
    /// Measured against a light panel: `systemGreen` itself is 1.97:1, so the metric
    /// hue cannot carry a segment no matter how the segments are ordered, and
    /// `ChartPalette.composition` ramps down to 28% opacity, which is fainter still.
    /// Apple's system hues are all in that range in light mode, so "use distinct hues"
    /// cannot meet a 3:1 bar either. Four compressed steps of the label colour can:
    /// they land at 13.7, 8.9, 5.8 and 3.9:1, roughly 30 RGB apart from each other, and
    /// the palest still reads against the track.
    private static let compositionShades: [Double] = [1.0, 0.85, 0.70, 0.55]

    private static func readableSegments(_ segments: [CompositionSegment]) -> [CompositionSegment] {
        var index = 0
        return segments.map { segment in
            guard !segment.isRemainder else { return segment }
            defer { index += 1 }
            let shade = compositionShades[min(index, compositionShades.count - 1)]
            return CompositionSegment(id: segment.id, label: segment.label,
                                      shortLabel: segment.shortLabel,
                                      value: segment.value,
                                      tint: Design.Palette.primaryText.opacity(shade),
                                      isRemainder: false)
        }
    }

    // MARK: GPU

    private var gpuDetail: some View {
        section(engine.gpu) { gpu in
            if let device = gpu.primary {
                VStack(alignment: .leading, spacing: Design.Space.xs) {
                    if let used = device.vramUsedBytes, let total = device.vramTotalBytes, total > 0 {
                        PanelBarRow(label: "VRAM",
                                    value: "\(formatter.memory(used)) of \(formatter.memory(total))",
                                    fraction: Double(used) / Double(total),
                                    tint: tint)
                    }
                    let entries = gpuEntries(device)
                    if !entries.isEmpty { PanelDetailGrid(entries: entries) }
                    history(available: device.utilization != nil)
                }
            } else {
                UnavailableNote(.failed("No graphics device reported"))
            }
        }
    }

    /// The device is named in the header, so the detail carries only what the header
    /// cannot: the split between renderer and tiler, where the driver reports it.
    private func gpuEntries(_ device: GPUDevice) -> [PanelDetailEntry] {
        var entries: [PanelDetailEntry] = []
        if let renderer = device.rendererUtilization {
            entries.append(PanelDetailEntry("Renderer", formatter.percent(renderer)))
        }
        if let tiler = device.tilerUtilization {
            entries.append(PanelDetailEntry("Tiler", formatter.percent(tiler)))
        }
        return entries
    }

    // MARK: Network

    private var networkDetail: some View {
        section(engine.network) { network in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                // The header's paired readout already says both rates, so the
                // detail starts at the addresses. A full row rather than the grid:
                // alone, it would sit in the left column and the address would
                // end mid-panel instead of on the right edge like the public one.
                if let ip = network.localIPv4 {
                    CopyableReadoutRow("Local IP", ip)
                } else if let name = network.primaryInterfaceName {
                    ReadoutRow("Interface", name)
                }
                if let publicIP = publicIPValue(network.publicIP) {
                    // Full width rather than a grid cell, the way the battery's adapter
                    // row is: a grid cell is half of 340pt and truncated "203.0.113…"
                    // after the label, and an IPv6 answer is three times longer again.
                    CopyableReadoutRow("Public IP", publicIP)
                }
                if let router = network.routerIPv4 {
                    CopyableReadoutRow("Router", router)
                }
                if !network.dnsServers.isEmpty {
                    ReadoutRow("DNS", network.dnsServers.joined(separator: " · "))
                }
                if let latency = latencyValue(network.latency, loss: network.packetLoss) {
                    HStack(spacing: Design.Space.rowGap) {
                        Text("Latency")
                            .font(Design.Text.label)
                            .foregroundStyle(Design.Palette.secondaryText)
                            .lineLimit(1)
                        Spacer(minLength: Design.Space.m)
                        Text(latency)
                            .font(Design.Text.value)
                            .foregroundStyle(Design.Palette.primaryText)
                            .lineLimit(1)
                        Button {
                            engine.triggerLatencyProbe()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                                .font(Design.Text.micro)
                                .foregroundStyle(Design.Palette.secondaryText)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Retest latency")
                    }
                }
                if let primary = network.interfaces.first(where: { $0.name == network.primaryInterfaceName }) {
                    if let ip6 = primary.ipv6 {
                        CopyableReadoutRow("Local IPv6", ip6)
                    }
                    if let mac = primary.macAddress {
                        let private_ = primary.factoryMacAddress != nil
                            && primary.factoryMacAddress != mac
                        CopyableReadoutRow("MAC", private_ ? "\(mac) · private" : mac)
                        if private_, let factory = primary.factoryMacAddress {
                            CopyableReadoutRow("Factory MAC", factory)
                        }
                    }
                }
                if engine.networkUsage.today.combined() > 0 {
                    ReadoutRow("Today", usageText(engine.networkUsage.today))
                }
                if engine.networkUsage.total.combined() > 0 {
                    ReadoutRow("Total", usageText(engine.networkUsage.total))
                }
                if let wifi = network.wifi, let quality = wifi.signalQuality {
                    // The network's name labels its own signal bar; a row that said
                    // "Signal" and a row that said "Network" would be two lines
                    // saying one thing.
                    PanelBarRow(label: wifi.ssid ?? "Signal", value: signalValue(wifi),
                                fraction: quality, tint: tint)
                }
                history()
            }
        }
    }

    /// What the public IP row says, or nil when there should be no row at all.
    ///
    /// The fetcher reports `.unsupported` while the toggle is off, and that is the one
    /// state with no row: a permanently empty field would read as a lookup that keeps
    /// failing rather than a feature nobody asked for. The fetcher's failure text is a
    /// sentence and this line holds a value, so the row says only which of the three
    /// things is true: an address, a lookup in flight, or one that did not answer.
    private func publicIPValue(_ state: MetricState<String>) -> String? {
        switch state {
        case .value(let address): return address
        case .failure(.unsupported): return nil
        case .failure(.pending): return "Looking up…"
        case .failure: return MetricFormatter.unavailable
        }
    }

    /// "↓ 1.2 GB · ↑ 340 MB": both directions of a usage total on one row.
    private func usageText(_ totals: NetworkUsageLedger.Totals) -> String {
        "↓ \(formatter.storage(totals.download)) · ↑ \(formatter.storage(totals.upload))"
    }

    /// The latency row, or nil while the panel is closed — the probes are off
    /// then, so "no row" is what "not probed" looks like rather than an idle field.
    /// The loss figure rides in the same row: "42 ms · 0% loss" — two answers to
    /// one question about the same path.
    private func latencyValue(_ state: MetricState<TimeInterval>,
                              loss: MetricState<Double>) -> String? {
        var latency: String?
        switch state {
        case .value(let seconds): latency = formatter.fixed(seconds * 1_000, decimals: 0) + " ms"
        case .failure(.unsupported): break
        case .failure(.pending): latency = "Probing…"
        case .failure: latency = MetricFormatter.unavailable
        }
        var lossText: String?
        if case .value(let fraction) = loss {
            lossText = "\(formatter.fixed(fraction * 100, decimals: 0))% loss"
        }
        guard latency != nil || lossText != nil else { return nil }
        return [latency, lossText].compactMap { $0 }.joined(separator: " · ")
    }

    /// Signal strength with the negotiated rate beside it: the two together are what
    /// answer "is my Wi-Fi the problem", and neither is worth a row of its own.
    private func signalValue(_ wifi: WiFiInfo) -> String {
        var text = wifi.rssi.map { "\($0) dBm" } ?? MetricFormatter.unavailable
        if let rate = wifi.transmitRateMbps {
            text += " · \(formatter.fixed(rate, decimals: 0)) Mbps"
        }
        return text
    }

    // MARK: Disk

    private var diskDetail: some View {
        section(engine.disk) { disk in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                ForEach(disk.volumes) { volume in
                    volumeRow(volume)
                }
                culprits("Reading and writing the most", by: diskTotal) {
                    formatter.diskRate(diskTotal($0))
                }
                PanelDetailGrid(entries: [
                    PanelDetailEntry("Read", formatter.diskRate(disk.readBytesPerSecond)),
                    PanelDetailEntry("Write", formatter.diskRate(disk.writeBytesPerSecond)),
                    // Counters since boot: how much the storage has ever moved, the
                    // closest thing to a wear reading this OS will hand out.
                    PanelDetailEntry("Lifetime read", formatter.storage(disk.totalReadBytes)),
                    PanelDetailEntry("Lifetime written", formatter.storage(disk.totalWriteBytes)),
                ])
                history()
            }
        }
    }

    /// Every figure in this module is derived from `availableBytes`, including the
    /// headline.
    ///
    /// Mixing bases is what made the old row unreconcilable: the headline said
    /// "185 GB free" from `availableBytes` while the row said "71% of 494 GB" from
    /// `freeBytes`, and 29% of 494 is 143, not 185. The two differ by purgeable space,
    /// which macOS counts as available and the filesystem counts as used. Following
    /// Finder and reporting one of them everywhere means free + used = total, on screen,
    /// with no footnote.
    private func volumeRow(_ volume: VolumeInfo) -> some View {
        let total = Double(volume.totalBytes)
        let remaining = total > 0 ? Double(volume.availableBytes) / total : 0
        let occupied = volume.totalBytes > volume.availableBytes
            ? volume.totalBytes - volume.availableBytes : 0
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Text(volume.name)
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                if volume.isEjectable {
                    Image(systemName: "eject.fill")
                        .font(Design.Text.micro)
                        .foregroundStyle(Design.Palette.tertiaryText)
                }
                Spacer(minLength: Design.Space.m)
                Text("\(formatter.storage(occupied)) of \(formatter.storage(volume.totalBytes))")
                    .font(Design.Text.caption.monospacedDigit())
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
            }
            CapacityBar(fraction: 1 - remaining, tint: tint)
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Battery

    private var batteryDetail: some View {
        section(engine.power) { power in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                if power.hasBattery, let percentage = power.percentage {
                    batteryOutlook(power, percentage: percentage)
                }
                if let adapter = adapterSummary(power) {
                    ReadoutRow("Adapter", adapter)
                }
                let entries = powerEntries(power)
                if !entries.isEmpty { PanelDetailGrid(entries: entries) }
                culprits("Using significant energy",
                         by: { ($0.energyImpact ?? 0) >= Self.significantWatts ? $0.energyImpact ?? 0 : 0 }) {
                    formatter.watts($0.energyImpact, decimals: 2)
                }
                if !power.accessories.isEmpty {
                    VStack(alignment: .leading, spacing: Design.Space.xs) {
                        PanelSectionLabel("Devices")
                        ForEach(power.accessories) { accessory in
                            accessoryRow(accessory)
                        }
                    }
                    .padding(.top, Design.Space.xs)
                }
                history(available: power.hasBattery && power.percentage != nil)
            }
        }
    }

    /// The answer the battery is opened for, how long, set larger than the rows under
    /// it, with what the charger is doing beside it and the charge as a bar beneath.
    private func batteryOutlook(_ power: PowerSnapshot, percentage: Double) -> some View {
        let state = chargeState(power) ?? (power.isPluggedIn ? "On power adapter" : "On battery")
        let outlook: String = {
            if power.isCharging, let toFull = power.timeToFull { return "Full in " + formatter.duration(toFull) }
            if !power.isPluggedIn, let toEmpty = power.timeToEmpty { return formatter.duration(toEmpty) + " left" }
            return state
        }()
        return VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(alignment: .firstTextBaseline, spacing: Design.Space.s) {
                Text(outlook)
                    .font(Design.Text.headline)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                Spacer(minLength: Design.Space.s)
                if outlook != state {
                    Text(state)
                        .font(Design.Text.caption)
                        .foregroundStyle(Design.Palette.secondaryText)
                        .lineLimit(1)
                }
            }
            CapacityBar(fraction: percentage / 100, tint: tint)
        }
        .accessibilityElement(children: .combine)
    }

    /// Laid out like a disk volume, name over its bar, rather than as a bar row:
    /// a bar row keeps 58 points for the label, and "AirPods Pro" with three part
    /// figures beside it needs the whole width.
    private func accessoryRow(_ accessory: AccessoryBattery) -> some View {
        VStack(alignment: .leading, spacing: Design.Space.xs) {
            HStack(spacing: Design.Space.xs) {
                Text(accessory.name)
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: Design.Space.m)
                Text(accessoryValue(accessory))
                    .font(Design.Text.caption.monospacedDigit())
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
            }
            CapacityBar(fraction: accessory.percent / 100, tint: tint)
        }
        .accessibilityElement(children: .combine)
    }

    /// "64%", or for earbuds each part in turn, "L 64%  R 71%  Case 90%", with
    /// "charging" after whatever is on power. The parts are what the user needs to
    /// know, since one flat bud is the one that gets swapped into the case.
    private func accessoryValue(_ accessory: AccessoryBattery) -> String {

        guard !accessory.parts.isEmpty else {
            let charge = formatter.percentValue(accessory.percent)
            return accessory.isCharging ? "\(charge) · charging" : charge
        }
        return accessory.parts.map { part in
            let label: String
            switch part.name.lowercased() {
            case "left": label = "L"
            case "right": label = "R"
            default: label = part.name
            }
            let charge = formatter.percentValue(part.percent)
            return part.isCharging ? "\(label) \(charge)⚡︎" : "\(label) \(charge)"
        }.joined(separator: "  ")
    }

    private func adapterSummary(_ power: PowerSnapshot) -> String? {

        if let name = power.adapterName { return name }
        if let watts = power.adapterWatts { return formatter.count(watts) + " W" }
        return nil
    }

    /// Only what the platform actually reported. A battery that does not publish a
    /// cycle count gets no cycle row, rather than a zero. A machine with no battery
    /// has nothing to say here that the header and the adapter row have not said.
    private func powerEntries(_ power: PowerSnapshot) -> [PanelDetailEntry] {
        guard power.hasBattery else { return [] }
        var entries: [PanelDetailEntry] = []
        if let health = power.healthPercent {
            entries.append(PanelDetailEntry("Health", formatter.percentValue(health)))
        }
        if let cycles = power.cycleCount {
            entries.append(PanelDetailEntry("Cycles", formatter.count(cycles)))
        }
        if let condition = power.condition {
            entries.append(PanelDetailEntry("Condition", condition))
        }
        if power.isLowPowerMode {
            entries.append(PanelDetailEntry("Low Power", "On"))
        }
        return entries
    }

    /// What the charger is doing, in the words the system's battery menu uses. Nil on
    /// battery, where "Time left" already says it.
    private func chargeState(_ power: PowerSnapshot) -> String? {
        if power.isCharging { return power.isChargingSlowly ? "Charging slowly" : "Charging" }
        if power.isFullyCharged, power.isPluggedIn { return "Charged" }
        if power.isOptimizedChargingPaused { return "Charging on hold" }
        return nil
    }

    /// Below a twentieth of a watt a process is background noise on Apple silicon, and
    /// listing it would make an idle machine look busy. Measured, not guessed: an
    /// editor helper at 45% of an efficiency core drew 0.10 W.
    static let significantWatts = 0.05

    // MARK: Thermal

    private var thermalDetail: some View {
        section(engine.thermal) { thermal in
            VStack(alignment: .leading, spacing: Design.Space.xs) {
                PanelDetailGrid(entries: thermalEntries(thermal))
                // Fans are read out rather than gauged: a stopped fan is a normal
                // state on a Mac that is not working hard, and an empty dial next
                // to a healthy machine reads as a broken sensor. "0 RPM" cannot be
                // misread. Full-width rows: "1,765 RPM · 22%" does not fit a half
                // grid cell next to the fan's name without truncating.
                ForEach(thermal.fans) { fan in
                    ReadoutRow(fan.name, fanText(fan))
                }
                if let reason = thermal.sensorsUnavailableReason {
                    UnavailableNote(.unsupported(reason))
                }
                history(available: thermal.cpuCelsius != nil)
            }
        }
    }

    private func thermalEntries(_ thermal: ThermalSnapshot) -> [PanelDetailEntry] {
        var entries = [PanelDetailEntry("Pressure", thermal.pressure.label)]
        if let gpu = thermal.gpuCelsius {
            entries.append(PanelDetailEntry("GPU", formatter.temperature(gpu)))
        }
        return entries
    }

    /// "1,820 RPM · 23%" — the RPM it is spinning at and how far up its rated
    /// range that is, which is the number RPM alone cannot carry.
    private func fanText(_ fan: FanInfo) -> String {
        if let maxRPM = fan.maxRPM, maxRPM > 0 {
            let pct = formatter.percentValue(100 * fan.currentRPM / maxRPM)
            return "\(pct) (\(formatter.rpm(fan.currentRPM)))"
        }
        return formatter.rpm(fan.currentRPM)
    }

    // MARK: Processes

    private var processesDetail: some View {
        section(engine.processes) { processes in
            VStack(alignment: .leading, spacing: 0) {
                ForEach(topProcesses(processes)) { process in
                    processRow(process, value: processValue(process))
                }
            }
        }
    }

    private var sortKey: ProcessSortKey { PanelSettings.processSortKey }

    private func topProcesses(_ processes: ProcessSnapshot) -> [ProcessRow] {
        let count = PanelSettings.processRowCount
        let sorted = processes.processes.sorted { a, b in
            switch sortKey {
            case .cpu: return a.cpuPercent > b.cpuPercent
            case .memory: return a.memoryBytes > b.memoryBytes
            case .energy: return (a.energyImpact ?? 0) > (b.energyImpact ?? 0)
            case .diskIO: return diskTotal(a) > diskTotal(b)
            case .networkIO, .name: return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            case .pid: return a.pid < b.pid
            }
        }
        return Array(sorted.prefix(count))
    }

    private func diskTotal(_ process: ProcessRow) -> Double {
        (process.diskReadBytesPerSecond ?? 0) + (process.diskWriteBytesPerSecond ?? 0)
    }

    private func processRow(_ process: ProcessRow, value: String) -> some View {
        HStack(spacing: Design.Space.s) {
            processIcon(process)
            Text(process.name)
                .font(Design.Text.body)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: Design.Space.m)
            Text(value)
                .font(Design.Text.value)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .frame(width: PanelModuleView.processValueWidth, alignment: .trailing)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(process.name)
        .accessibilityValue(value)
        .contextMenu {
            Button(role: .destructive) {
                kill(process.pid, SIGTERM)
            } label: {
                Label("Quit Process (\(process.name))", systemImage: "xmark.circle")
            }
            Button(role: .destructive) {
                kill(process.pid, SIGKILL)
            } label: {
                Label("Force Quit (SIGKILL)", systemImage: "bolt.circle")
            }
            Divider()
            Button {
                actions.openActivityMonitor(module.activityMonitorTab)
            } label: {
                Label("Show in Activity Monitor", systemImage: "list.bullet.rectangle")
            }
            if let path = process.executablePath {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(process.pid)", forType: .string)
            } label: {
                Label("Copy PID (\(process.pid))", systemImage: "doc.on.doc")
            }
        }
    }

    /// A real icon for anything with a bundle, a symbol for everything else.
    ///
    /// Not `NSWorkspace.icon(for: .unixExecutable)`, which is what Activity Monitor
    /// uses: that icon is a black tile with "exec" written on it in small green type,
    /// and at the 12pt this row can afford the type disappears and it renders as a
    /// solid block. A symbol stays a symbol at any size.
    @ViewBuilder
    private func processIcon(_ process: ProcessRow) -> some View {
        switch PanelAppIcon.icon(for: process) {
        case .bundle(let image):
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .frame(width: Design.Space.l, height: Design.Space.l)
        case .executable:
            Image(systemName: "gearshape.fill")
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.secondaryText)
                .frame(width: Design.Space.l, height: Design.Space.l)
        }
    }

    private func processValue(_ process: ProcessRow) -> String {
        switch sortKey {
        case .cpu, .name, .pid: return formatter.unclampedPercent(process.cpuPercent)
        case .memory: return formatter.memory(process.memoryBytes)
        case .energy: return formatter.watts(process.energyImpact, decimals: 2)
        case .diskIO: return formatter.diskRate(diskTotal(process))
        case .networkIO: return MetricFormatter.unavailable
        }
    }

    // MARK: System

    private var systemDetail: some View {
        section(engine.system) { system in
            VStack(alignment: .leading, spacing: Design.Space.xxs) {
                ReadoutRow("Model", system.modelName)
                ReadoutRow("Chip", system.chipName)
                ReadoutRow(system.osName, system.osVersion)
                if let display = system.displaySummary {
                    ReadoutRow("Display", display)
                }
            }
        }
    }

}
