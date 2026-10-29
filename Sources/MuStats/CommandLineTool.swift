import Foundation
import MuStatsKit

/// `mustats`: the readings from a terminal, for scripts, prompts and status lines.
///
///     mustats                      the menu bar app
///     mustats status [--json]      one line per module
///     mustats cpu|memory|gpu|disk|network|battery|temp [--json]
///     mustats top [-n 10] [--sort cpu|memory|energy] [--json]
///     mustats watch [module] [--interval 2]
///
/// Homebrew links the app's binary as `mustats`; the app itself is never launched.
/// Every command samples twice a second apart, because CPU, network and disk are
/// rates and a single read of a counter has nothing to compare against.
enum CommandLineTool {

    static let modules = ["cpu", "memory", "gpu", "disk", "network", "battery", "temp"]
    static let commands: Set<String> = Set(modules + ["status", "top", "watch", "help", "version"])

    /// Returns true when the arguments were a command and it ran.
    static func run(_ arguments: [String]) -> Bool {
        guard let command = arguments.first, commands.contains(command) else { return false }
        var rest = Array(arguments.dropFirst())
        let json = rest.contains("--json")
        rest.removeAll { $0 == "--json" }
        let formatter = MetricFormatter(settings: userSettings().general)

        switch command {
        case "help":
            print(help)
        case "version":
            let info = Bundle.main.infoDictionary
            print("μStats \(info?["CFBundleShortVersionString"] as? String ?? "dev") (\(info?["CFBundleVersion"] as? String ?? "0"))")
        case "status":
            let snapshot = Sampler(modules: Set(modules)).read()
            output(Self.modules.compactMap { Report.make($0, snapshot, formatter) }, json: json)
        case "top":
            top(rest, json: json, formatter: formatter)
        case "watch":
            watch(rest, formatter: formatter)
        default:
            let snapshot = Sampler(modules: [command]).read()
            output([Report.make(command, snapshot, formatter)].compactMap { $0 }, json: json)
        }
        return true
    }

    // MARK: Commands

    private static func top(_ arguments: [String], json: Bool, formatter: MetricFormatter) {
        var count = 10
        var sort = "cpu"
        var index = 0
        while index < arguments.count {
            switch arguments[index] {
            case "-n":
                index += 1
                count = Int(arguments[safe: index] ?? "") ?? count
            case "--sort":
                index += 1
                sort = arguments[safe: index] ?? sort
            default:
                fail("unknown option '\(arguments[index])' for top")
            }
            index += 1
        }
        guard ["cpu", "memory", "energy"].contains(sort) else { fail("--sort takes cpu, memory or energy") }

        let rows = (Sampler(modules: ["top"]).read().processes.value?.processes ?? [])
            .sorted {
                switch sort {
                case "memory": return $0.memoryBytes > $1.memoryBytes
                case "energy": return ($0.energyImpact ?? 0) > ($1.energyImpact ?? 0)
                default: return $0.cpuPercent > $1.cpuPercent
                }
            }
            .prefix(max(count, 1))

        if json {
            let items = rows.map {
                TopItem(pid: $0.pid, name: $0.name.trimmingCharacters(in: .whitespaces), cpuPercent: $0.cpuPercent,
                        memoryBytes: $0.memoryBytes, energyWatts: $0.energyImpact)
            }
            printJSON(items)
            return
        }
        print(pad("PID", 7) + pad("CPU", 9) + pad("MEMORY", 11) + pad("ENERGY", 9) + "NAME")
        for row in rows {
            print(pad("\(row.pid)", 7)
                  + pad(formatter.unclampedPercent(row.cpuPercent), 9)
                  + pad(formatter.memory(row.memoryBytes), 11)
                  + pad(row.energyImpact.map { formatter.watts($0) } ?? "-", 9)
                  + row.name.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Redraws in place until Ctrl-C. The sampler keeps its collectors between reads,
    /// so after the first second every refresh is one read, not two.
    private static func watch(_ arguments: [String], formatter: MetricFormatter) {
        var interval: TimeInterval = 2
        var selected: [String] = modules
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--interval" {
                index += 1
                interval = max(0.5, Double(arguments[safe: index] ?? "") ?? interval)
            } else if modules.contains(argument) {
                selected = [argument]
            } else if argument != "status" {
                fail("watch takes a module (\(modules.joined(separator: ", "))) and --interval")
            }
            index += 1
        }
        let sampler = Sampler(modules: Set(selected))
        var snapshot = sampler.read()
        var drawn = 0
        while true {
            let lines = selected.compactMap { Report.make($0, snapshot, formatter)?.line }
            // Up over what was drawn last time, then each line cleared as it is rewritten.
            if drawn > 0 { FileHandle.standardOutput.write(Data("\u{1B}[\(drawn)A".utf8)) }
            for line in lines { print("\u{1B}[2K" + line) }
            fflush(stdout)
            drawn = lines.count
            Thread.sleep(forTimeInterval: interval)
            snapshot = sampler.next()
        }
    }

    // MARK: Output

    private static func output(_ reports: [Report], json: Bool) {
        if json {
            printJSON(reports.map(\.values))
        } else {
            for report in reports { print(report.line) }
        }
    }

    private static func printJSON<T: Encodable>(_ value: T) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else { fail("could not encode the output") }
        print(String(decoding: data, as: UTF8.self))
    }

    private static func pad(_ text: String, _ width: Int) -> String {
        text.count >= width ? text + " " : text + String(repeating: " ", count: width - text.count)
    }

    private static func fail(_ message: String) -> Never {
        FileHandle.standardError.write(Data("mustats: \(message)\n".utf8))
        exit(2)
    }

    /// The units the user picked in the app, so the terminal says °F or bits when the
    /// menu bar does. Read straight from the file: the store would start watching it.
    private static func userSettings() -> Settings {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        guard let url = base?.appendingPathComponent("muStats/settings.json"),
              let data = try? Data(contentsOf: url),
              let settings = try? JSONDecoder().decode(Settings.self, from: data) else { return Settings() }
        return settings
    }

    static let help = """
    mustats, the μStats readings from a terminal

      mustats status [--json]                     every module, one line each
      mustats cpu|memory|gpu|disk|network|battery|temp [--json]
      mustats top [-n 10] [--sort cpu|memory|energy] [--json]
      mustats watch [module] [--interval 2]       refresh in place, Ctrl-C to stop
      mustats version

    Rates (CPU, network, disk) are measured over one second, so each command takes
    about a second to answer.
    """
}

private struct TopItem: Encodable {
    let pid: Int32
    let name: String
    let cpuPercent: Double
    let memoryBytes: UInt64
    let energyWatts: Double?
}

/// One module as a line for people and as numbers for scripts.
private struct Report {
    var line: String
    var values: [String: JSONValue]

    static func make(_ module: String, _ s: SystemSnapshot, _ f: MetricFormatter) -> Report? {
        func label(_ name: String) -> String { name.padding(toLength: 12, withPad: " ", startingAt: 0) }
        switch module {
        case "cpu":
            guard let cpu = s.cpu.value else { return nil }
            return Report(line: label("CPU") + "\(f.percent(cpu.total.busy))  load \(f.fixed(cpu.loadAverage.one, decimals: 2))",
                          values: ["module": "cpu", "busy": .number(cpu.total.busy),
                                   "user": .number(cpu.total.user), "system": .number(cpu.total.system),
                                   "load1": .number(cpu.loadAverage.one), "cores": .number(Double(cpu.perCore.count))])
        case "memory":
            guard let m = s.memory.value else { return nil }
            return Report(line: label("Memory") + "\(f.memory(m.usedBytes)) of \(f.memory(m.totalBytes))  pressure \(f.percent(m.pressureFraction))",
                          values: ["module": "memory", "usedBytes": .number(Double(m.usedBytes)),
                                   "totalBytes": .number(Double(m.totalBytes)), "pressure": .number(m.pressureFraction),
                                   "swapUsedBytes": .number(Double(m.swapUsedBytes))])
        case "gpu":
            guard let gpu = s.gpu.value?.primary else { return nil }
            let util = gpu.utilization.map { f.percent($0) } ?? "-"
            var values: [String: JSONValue] = ["module": "gpu", "name": .string(gpu.name)]
            if let u = gpu.utilization { values["utilization"] = .number(u) }
            return Report(line: label("GPU") + "\(util)  \(gpu.name)", values: values)
        case "disk":
            guard let disk = s.disk.value else { return nil }
            var line = label("Disk")
            var values: [String: JSONValue] = ["module": "disk", "readBytesPerSecond": .number(disk.readBytesPerSecond),
                                               "writeBytesPerSecond": .number(disk.writeBytesPerSecond)]
            if let root = disk.rootVolume {
                line += "\(f.storage(root.availableBytes)) free of \(f.storage(root.totalBytes))  "
                values["freeBytes"] = .number(Double(root.availableBytes))
                values["totalBytes"] = .number(Double(root.totalBytes))
            }
            line += "R \(f.diskRate(disk.readBytesPerSecond))  W \(f.diskRate(disk.writeBytesPerSecond))"
            return Report(line: line, values: values)
        case "network":
            guard let n = s.network.value else { return nil }
            var values: [String: JSONValue] = ["module": "network",
                                               "downloadBytesPerSecond": .number(n.downloadBytesPerSecond),
                                               "uploadBytesPerSecond": .number(n.uploadBytesPerSecond),
                                               "connection": .string(n.connectionType.label)]
            if let ip = n.localIPv4 { values["localIPv4"] = .string(ip) }
            return Report(line: label("Network") + "↓ \(f.networkRate(n.downloadBytesPerSecond))  ↑ \(f.networkRate(n.uploadBytesPerSecond))  \(n.connectionType.label)",
                          values: values)
        case "battery":
            guard let p = s.power.value, p.hasBattery, let pct = p.percentage else { return nil }
            var state = p.isCharging ? "charging" : (p.isPluggedIn ? "on power" : "on battery")
            if p.isCharging, let full = p.timeToFull { state += ", full in \(f.duration(full))" }
            if !p.isPluggedIn, let left = BatteryForecast.timeLeft(p) { state += ", \(f.duration(left)) left" }
            var values: [String: JSONValue] = ["module": "battery", "percent": .number(pct),
                                               "charging": .bool(p.isCharging), "pluggedIn": .bool(p.isPluggedIn)]
            if let w = p.batteryWatts { values["watts"] = .number(w) }
            return Report(line: label("Battery") + "\(f.percentValue(pct))  \(state)", values: values)
        case "temp":
            guard let t = s.thermal.value, t.cpuCelsius != nil || !t.fans.isEmpty else { return nil }
            var parts: [String] = []
            var values: [String: JSONValue] = ["module": "temp"]
            if let c = t.cpuCelsius { parts.append("CPU \(f.temperature(c))"); values["cpuCelsius"] = .number(c) }
            if let g = t.gpuCelsius { parts.append("GPU \(f.temperature(g))"); values["gpuCelsius"] = .number(g) }
            if let fan = t.fans.first { parts.append("fan \(f.rpm(fan.currentRPM))"); values["fanRPM"] = .number(fan.currentRPM) }
            return Report(line: label("Temperature") + parts.joined(separator: "  "), values: values)
        default:
            return nil
        }
    }
}

private enum JSONValue: Encodable, ExpressibleByStringLiteral {
    case number(Double)
    case string(String)
    case bool(Bool)

    init(stringLiteral value: String) { self = .string(value) }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .number(let n): try container.encode(n)
        case .string(let s): try container.encode(s)
        case .bool(let b): try container.encode(b)
        }
    }
}

/// The collectors a command needs, sampled the way the app samples them.
private final class Sampler {
    private let cpu = CPUCollector()
    private let memory = MemoryCollector()
    private let gpu = GPUCollector()
    private let network = NetworkCollector()
    private let disk = DiskCollector()
    private let power = PowerCollector()
    private let thermal = ThermalCollector()
    private let processes = ProcessCollector()
    private let wanted: Set<CollectorID>
    private var last: [CollectorID: ContinuousClock.Instant] = [:]
    private var snapshot = SystemSnapshot.empty

    init(modules: Set<String>) {
        var ids = Set<CollectorID>()
        for module in modules {
            switch module {
            case "cpu": ids.insert(.cpu)
            case "memory": ids.insert(.memory)
            case "gpu": ids.insert(.gpu)
            case "disk": ids.insert(.disk)
            case "network": ids.insert(.network)
            case "battery": ids.insert(.power)
            case "temp": ids.insert(.thermal)
            case "top": ids.insert(.processes)
            default: break
            }
        }
        wanted = ids
    }

    /// Two reads a second apart: the first sets the baseline every rate is measured
    /// from. The process list needs one more, because its first read only rebaselines
    /// and the energy each process drew is measured from the second.
    func read() -> SystemSnapshot {
        _ = next()
        if wanted.contains(.processes) {
            Thread.sleep(forTimeInterval: 0.3)
            _ = next()
        }
        Thread.sleep(forTimeInterval: 1)
        return next()
    }

    func next() -> SystemSnapshot {
        func sample<S: MetricSource>(_ source: S) -> MetricState<S.Output>? {
            guard wanted.contains(source.identifier) else { return nil }
            if last[source.identifier] == nil { source.start() }
            let now = Monotonic.now
            let elapsed = last[source.identifier].map { Monotonic.seconds(since: $0) } ?? 0
            last[source.identifier] = now
            return source.collect(context: SampleContext(elapsed: elapsed, isFirstSample: elapsed == 0,
                                                          activity: .panel))
        }
        if let s = sample(cpu) { snapshot.cpu = s }
        if let s = sample(memory) { snapshot.memory = s }
        if let s = sample(gpu) { snapshot.gpu = s }
        if let s = sample(network) { snapshot.network = s }
        if let s = sample(disk) { snapshot.disk = s }
        if let s = sample(power) { snapshot.power = s }
        if let s = sample(thermal) { snapshot.thermal = s }
        if let s = sample(processes) { snapshot.processes = s }
        return snapshot
    }
}
