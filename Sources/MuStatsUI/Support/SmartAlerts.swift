import Foundation
import MuStatsKit

/// A notification worked out from what the Mac is doing rather than from a threshold
/// the user set: a process running away, a reading unusual for this Mac, a heavy app
/// left running as the charger comes out.
struct SmartAlert: Equatable {
    enum Category: String {
        /// Offers Quit and Ignore.
        case runaway
        /// Offers Quit.
        case quittable
        /// Information only.
        case plain
    }

    var identifier: String
    var title: String
    var body: String
    var category: Category
    /// The process the Quit button acts on.
    var pid: Int32?
    /// The name Ignore remembers.
    var processName: String?
}

/// A process keeping a whole core busy, minute after minute, while nobody is at
/// the Mac.
///
/// Fed only from process lists read fresh this tick. With the panel closed those are
/// the two reads a busy minute gets, so a process that keeps a core busy shows up in
/// every minute of its run and a streak that misses a minute has ended.
struct RunawayWatch {
    /// Most of one core, the way Activity Monitor counts it.
    static let busyPercent = 80.0
    /// How long it has to keep going before it is a runaway and not a burst.
    static let sustained: TimeInterval = 10 * 60
    /// How long nobody has to have touched the Mac: a long build the user started
    /// and is waiting on is not a runaway.
    static let awayFor: TimeInterval = 10 * 60
    /// A gap longer than this between two sightings ends the streak.
    static let gap: TimeInterval = 150
    static let cooldown: TimeInterval = 60 * 60

    private struct Streak {
        var name: String
        var since: Date
        var last: Date
    }

    private var streaks: [Int32: Streak] = [:]
    private var lastAlert: [String: Date] = [:]

    mutating func update(processes: [ProcessRow], ownPID: Int32, idle: TimeInterval?,
                         ignored: Set<String>, now: Date) -> SmartAlert? {
        let busy = processes.filter {
            $0.cpuPercent >= Self.busyPercent && !$0.isAppleSignedSystem
                && $0.pid != ownPID && !ignored.contains($0.name)
        }
        var next: [Int32: Streak] = [:]
        for process in busy {
            if var streak = streaks[process.pid], streak.name == process.name,
               now.timeIntervalSince(streak.last) <= Self.gap {
                streak.last = now
                next[process.pid] = streak
            } else {
                next[process.pid] = Streak(name: process.name, since: now, last: now)
            }
        }
        streaks = next

        guard let idle, idle >= Self.awayFor else { return nil }
        let due = streaks
            .filter { now.timeIntervalSince($0.value.since) >= Self.sustained }
            .filter { lastAlert[$0.value.name].map { now.timeIntervalSince($0) >= Self.cooldown } ?? true }
            .max { $0.value.since > $1.value.since }
        guard let (pid, streak) = due else { return nil }
        lastAlert[streak.name] = now
        let minutes = Int(now.timeIntervalSince(streak.since) / 60)
        let app = busy.first { $0.pid == pid }.map(PanelCulprit.appName(for:)) ?? streak.name
        return SmartAlert(identifier: "smart.runaway.\(streak.name)",
                          title: "\(app) is keeping a core busy",
                          body: "It has used a full core for \(minutes) minutes while you were away.",
                          category: .runaway, pid: pid, processName: streak.name)
    }
}

/// A reading well outside what this Mac usually does at this hour.
///
/// The usual comes from the month tier: the hourly mean at this hour on each earlier
/// day that has one. The now is the last ten minutes of the day tier. Both are kept
/// anyway, so the check is a few dozen cell reads once a minute.
struct UnusualWatch {
    struct Metric {
        let key: SeriesKey
        let title: String
        /// Below this the reading is unremarkable however rare it is for this Mac.
        let floor: Double
        /// The reading has to be at least this far above the usual.
        let margin: Double
        let format: (Double, MetricFormatter) -> String
        let note: NoteKind?
    }

    static let metrics: [Metric] = [
        Metric(key: .cpuTotal, title: "CPU is unusually busy", floor: 0.35, margin: 0.25,
               format: { v, f in f.percent(v) }, note: .cpu),
        Metric(key: .cpuTemperature, title: "Running hotter than usual", floor: 75, margin: 12,
               format: { v, f in f.temperature(v) }, note: .cpu),
        Metric(key: .memoryPressure, title: "Memory pressure is unusually high", floor: 0.5, margin: 0.2,
               format: { v, f in f.percent(v) }, note: .memory),
    ]

    /// The window "now" is averaged over.
    static let window = 10
    /// Minutes of it that must hold a sample.
    static let windowMinimum = 8
    /// Earlier days at this hour the usual needs before it means anything.
    static let daysMinimum = 7
    static let cooldown: TimeInterval = 3 * 60 * 60

    private var lastMinute: Int?
    private var lastAlert: [SeriesKey: Date] = [:]

    mutating func update(day: MinuteHistory, month: MinuteHistory, formatter: MetricFormatter,
                         now: Date, calendar: Calendar = .current) -> [SmartAlert] {
        let minute = Int(now.timeIntervalSince1970 / 60)
        guard minute != lastMinute else { return [] }
        lastMinute = minute

        var alerts: [SmartAlert] = []
        for metric in Self.metrics {
            guard lastAlert[metric.key].map({ now.timeIntervalSince($0) >= Self.cooldown }) ?? true,
                  let current = Self.recent(metric.key, day: day, now: now),
                  let usual = Self.usual(metric.key, month: month, now: now),
                  Self.isUnusual(current: current, usual: usual, floor: metric.floor, margin: metric.margin)
            else { continue }
            lastAlert[metric.key] = now
            let hour = calendar.component(.hour, from: now)
            var body = "\(metric.format(current, formatter)) for the last \(Self.window) minutes. "
                + "Around \(String(format: "%02d", hour)):00 this Mac usually sits near \(metric.format(usual.median, formatter))."
            if let kind = metric.note,
               let name = (0..<Self.window).lazy.compactMap({ day.note(kind, at: now.addingTimeInterval(-60 * Double($0)))?.name }).first {
                body += " Top: \(name)."
            }
            alerts.append(SmartAlert(identifier: "smart.unusual.\(metric.key.rawValue)",
                                     title: metric.title, body: body, category: .plain))
        }
        return alerts
    }

    /// Mean of the last ten minutes, or nil when too few of them were sampled.
    static func recent(_ key: SeriesKey, day: MinuteHistory, now: Date) -> Double? {
        let values = (0..<window).compactMap { day.average(key, at: now.addingTimeInterval(-60 * Double($0))) }
        guard values.count >= windowMinimum else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    struct Usual: Equatable {
        var median: Double
        /// Median absolute deviation: how far a typical day strays from the median.
        var spread: Double
    }

    /// This hour on each earlier day of the month tier that has it.
    static func usual(_ key: SeriesKey, month: MinuteHistory, now: Date) -> Usual? {
        let values = (1..<30).compactMap { month.average(key, at: now.addingTimeInterval(-86_400 * Double($0))) }
        guard values.count >= daysMinimum else { return nil }
        let median = Self.median(values)
        let spread = Self.median(values.map { abs($0 - median) })
        return Usual(median: median, spread: spread)
    }

    /// Well past the usual by the metric's own margin, by five typical deviations,
    /// and over a floor where it matters at all.
    static func isUnusual(current: Double, usual: Usual, floor: Double, margin: Double) -> Bool {
        current >= floor
            && current - usual.median >= margin
            && current - usual.median >= 5 * usual.spread
    }

    private static func median(_ values: [Double]) -> Double {
        let sorted = values.sorted()
        let middle = sorted.count / 2
        return sorted.count % 2 == 0 ? (sorted[middle - 1] + sorted[middle]) / 2 : sorted[middle]
    }
}

/// The moment the charger comes out, a word if something heavy is still running.
///
/// The process list is not being read with the panel closed, so unplugging asks for
/// two reads; the second carries the energy each process drew. If nothing heavy
/// turns up within a minute, nothing is said.
struct UnplugWatch {
    /// Watts a process has to draw for its time on battery to be worth a word.
    static let heavyWatts = 3.0
    static let patience: TimeInterval = 60

    private var wasPluggedIn: Bool?
    private var waitingSince: Date?

    struct Outcome {
        var requestsWitness = false
        var alert: SmartAlert?
    }

    mutating func update(power: PowerSnapshot?, processes: [ProcessRow]?, ownPID: Int32,
                         formatter: MetricFormatter, now: Date) -> Outcome {
        var outcome = Outcome()
        guard let power, power.hasBattery else { return outcome }
        defer { wasPluggedIn = power.isPluggedIn }
        if power.isPluggedIn {
            waitingSince = nil
            return outcome
        }
        if wasPluggedIn == true {
            waitingSince = now
            outcome.requestsWitness = true
            return outcome
        }
        guard let since = waitingSince else { return outcome }
        guard now.timeIntervalSince(since) <= Self.patience else {
            waitingSince = nil
            return outcome
        }
        guard let processes,
              let top = processes
                .filter({ !$0.isAppleSignedSystem && $0.pid != ownPID })
                .max(by: { ($0.energyImpact ?? 0) < ($1.energyImpact ?? 0) }),
              let watts = top.energyImpact else { return outcome }
        // An answer either way: heavy or not, the question this unplugging asked is settled.
        waitingSince = nil
        guard watts >= Self.heavyWatts else { return outcome }

        let app = PanelCulprit.appName(for: top)
        var body = "It keeps drawing power on battery."
        if let draw = BatteryForecast.draw(power), let left = BatteryForecast.timeLeft(power),
           let gain = BatteryForecast.gain(timeLeft: left, draw: draw, processWatts: watts),
           gain >= BatteryForecast.worthSaying {
            body = "Quitting it would add about \(formatter.uptime(gain)) of battery."
        }
        outcome.alert = SmartAlert(identifier: "smart.unplug",
                                   title: "\(app) is using \(formatter.watts(watts)) on battery",
                                   body: body, category: .quittable, pid: top.pid, processName: top.name)
        return outcome
    }
}
