import Foundation
import IOKit.ps
import notify

/// Per-source scheduling state. Generic so each concrete collector keeps its
/// strong type all the way to the snapshot — no `Any` boxing on the hot path.
final class SourceSlot<Source: MetricSource> {
    let source: Source
    private(set) var state: MetricState<Source.Output> = .pending
    private var lastSampled: ContinuousClock.Instant?
    private var isStarted = false
    /// Set when the source reports `.unsupported`. We never call it again this
    /// session — that is the whole point of distinguishing unsupported from failed.
    private(set) var isRetired = false
    private var consecutiveFailures = 0
    private var retryNotBefore: ContinuousClock.Instant?

    init(_ source: Source) { self.source = source }

    var identifier: CollectorID { source.identifier }

    /// Runs the source if it is enabled and due. Returns true when `state` changed.
    @discardableResult
    func tick(now: ContinuousClock.Instant,
              activity: SamplingActivity,
              isEnabled: Bool,
              baseInterval: TimeInterval,
              didWakeFromSleep: Bool,
              force: Bool = false,
              thermalCadenceMultiplier: Double = 1) -> Bool {
        guard isEnabled, !isRetired, activity.isSampling else {
            if !isEnabled && isStarted { suspend() ; return false }
            return false
        }

        if !isStarted {
            source.start()
            isStarted = true
        }

        if !force, let retryNotBefore, now < retryNotBefore { return false }

        let interval = max(source.preferredInterval, baseInterval)
            * activity.cadenceMultiplier * thermalCadenceMultiplier
        let elapsed: TimeInterval
        if let lastSampled {
            elapsed = Monotonic.seconds(since: lastSampled)
            // Sample slightly early rather than slightly late so a coalesced timer
            // does not systematically stretch the effective interval.
            guard force || elapsed >= interval * 0.9 else { return false }
        } else {
            elapsed = 0
        }

        let context = SampleContext(elapsed: elapsed,
                                    isFirstSample: lastSampled == nil,
                                    activity: activity,
                                    didWakeFromSleep: didWakeFromSleep)
        let newState = source.collect(context: context)
        lastSampled = now

        switch newState {
        case .value:
            consecutiveFailures = 0
            retryNotBefore = nil
        case .failure(let failure):
            if failure.isPermanent {
                isRetired = true
                source.stop()
                isStarted = false
            } else if failure == .pending {
                // A collector establishing its first baseline has not failed; the
                // reading it promised for the next tick must not be pushed out.
                retryNotBefore = nil
            } else {
                consecutiveFailures += 1
                let delay = consecutiveFailures >= 6
                    ? 60.0
                    : pow(2.0, Double(consecutiveFailures))
                retryNotBefore = now.advanced(by: .seconds(delay))
            }
        }

        let changed = newState != state
        state = newState
        return changed
    }

    /// Release resources but stay eligible to run again later.
    func suspend() {
        guard isStarted else { return }
        source.stop()
        isStarted = false
        lastSampled = nil
        retryNotBefore = nil
        consecutiveFailures = 0
    }

    /// Force the next tick to treat its counters as a fresh baseline.
    func invalidateBaseline() { lastSampled = nil }

    /// Whether the last collection happened at `instant`.
    func sampled(at instant: ContinuousClock.Instant) -> Bool { lastSampled == instant }

    func resetRetry() {
        consecutiveFailures = 0
        retryNotBefore = nil
    }

    func shutdown() {
        suspend()
        state = .pending
    }
}

/// Owns every collector and the sampling timer.
///
/// ## Threading
/// All state on this class is confined to `queue`, a single serial queue at
/// `.utility` QoS. Nothing here touches the main thread except the `onSnapshot`
/// callback, which is dispatched to the main actor. The class is `@unchecked
/// Sendable` because that confinement is enforced by construction, not by types.
public final class SamplingCore: @unchecked Sendable {

    // MARK: Sources

    private let cpuSlot: SourceSlot<CPUCollector>
    private let memorySlot: SourceSlot<MemoryCollector>
    private let gpuSlot: SourceSlot<GPUCollector>
    private let networkSlot: SourceSlot<NetworkCollector>
    private let diskSlot: SourceSlot<DiskCollector>
    private let powerSlot: SourceSlot<PowerCollector>
    private let thermalSlot: SourceSlot<ThermalCollector>
    private let processSlot: SourceSlot<ProcessCollector>
    private let systemSlot: SourceSlot<SystemInfoCollector>

    // MARK: Scheduling

    private let queue = DispatchQueue(label: "com.danesed.mustats.sampling", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var baseInterval: TimeInterval = 2
    /// The wall-clock minute the process list was last read for a peak, and whether
    /// the read that names the process is still owed. See `wantsPeakWitness`.
    private var witnessedMinute: Int?
    private var witnessFollowUpDue = false
    /// Machine-wide CPU, as a fraction of every core, above which a minute gets a
    /// look at the process list. A tenth is one runaway core on a twelve core Mac,
    /// which is the case a day chart most often has to explain.
    static let cpuWitnessThreshold = 0.10
    /// Memory pressure above which the minute gets the same look.
    static let memoryWitnessThreshold = 0.6
    /// Most of one core, as the share of the machine a single busy process makes.
    static let oneCoreShare = 0.8
    /// Set from outside to read the process list on the next two ticks whatever the
    /// load: unplugging asks, so the alert can say what is drawing the battery.
    private var witnessRequested = false
    private var activity: SamplingActivity = .menuBar
    private var enabledSources: Set<CollectorID> = Set(CollectorID.allCases)
    private var publicIPLookupEnabled = false
    private var pendingWakeFlag = false
    private var isRunning = false
    private var thermalCadenceMultiplier = 1.0
    /// Registration for powerd's "a power source changed" notification. Plugging in,
    /// unplugging, a charge hold starting and the percentage ticking over all post it,
    /// so the battery does not have to be polled to notice any of them.
    private var powerNotifyToken = NOTIFY_TOKEN_INVALID
    /// Set by that notification and spent by the next tick, which samples the power
    /// source whatever its cadence says. Not a sample of its own: every snapshot folds
    /// every metric into history, so an out-of-band tick would plant an extra point in
    /// each chart. The next regular tick is at most one update interval away.
    private var powerEventPending = false
    /// With events covering every change a user can see in the menu bar, the battery's
    /// own cadence only has to keep watts and time remaining fresh, which nothing reads
    /// until the panel or the widget is open. Until then it is polled this many times
    /// more slowly: five seconds becomes thirty.
    static let powerIdleCadenceMultiplier = 6.0
    /// True while only the menu bar is on screen and the machine is idle. See
    /// `updateQuietLocked`.
    private var isQuiet = false
    /// Whole-machine CPU below which a menu-bar-only session counts as quiet, and above
    /// which it stops. Two thresholds so a load sitting near one does not flip the
    /// cadence on every tick. A quarter of the machine because that is ordinary desk
    /// work on a many-core Mac: measured at 15 to 20% on twelve cores with an editor
    /// and a browser open, so a tenth was a quiet mode that never engaged.
    static let quietEnterBusy = 0.25
    static let quietExitBusy = 0.40
    /// How much more slowly a quiet session ticks. Every tick that changes the bar is
    /// a redraw paid once per menu bar AppKit mirrors the item into, and an idle
    /// machine's numbers are the ones least worth repainting every two seconds.
    static let quietCadenceMultiplier = 2.0
    /// Quiet and also still: the CPU has moved less than `steadyBand` between this many
    /// samples in a row. Nothing on the bar is changing, so it ticks slower again, and
    /// the first sample that moves past the band brings the quiet rate straight back.
    static let steadySamples = 5
    static let steadyBand = 0.03
    static let steadyCadenceMultiplier = 3.0
    /// Temperatures move over tens of seconds, and the sensor read is the most
    /// expensive one the menu bar pays for, so with only the bar on screen it is read
    /// at a third of the rate. The panel and the widget get every sample.
    static let thermalMenuBarMultiplier = 3.0
    private var isSteady = false
    private var steadyRun = 0
    private var lastBusy: Double?

    /// A single settings transaction keeps interval, source selection and network
    /// lookup changes on one queue hop. This matters while a settings control emits
    /// several revisions during a drag.
    public struct Configuration: Sendable, Equatable {
        public let baseInterval: TimeInterval
        public let enabledSources: Set<CollectorID>
        public let publicIPLookupEnabled: Bool

        public init(baseInterval: TimeInterval,
                    enabledSources: Set<CollectorID>,
                    publicIPLookupEnabled: Bool) {
            self.baseInterval = baseInterval
            self.enabledSources = enabledSources
            self.publicIPLookupEnabled = publicIPLookupEnabled
        }
    }

    /// Delivered on the main actor after every cycle that produced a change.
    private let onSnapshot: @Sendable @MainActor (SystemSnapshot) -> Void

    public init(onSnapshot: @escaping @Sendable @MainActor (SystemSnapshot) -> Void) {
        self.onSnapshot = onSnapshot
        self.cpuSlot = SourceSlot(CPUCollector())
        self.memorySlot = SourceSlot(MemoryCollector())
        self.gpuSlot = SourceSlot(GPUCollector())
        self.networkSlot = SourceSlot(NetworkCollector())
        self.diskSlot = SourceSlot(DiskCollector())
        self.powerSlot = SourceSlot(PowerCollector())
        self.thermalSlot = SourceSlot(ThermalCollector())
        self.processSlot = SourceSlot(ProcessCollector())
        self.systemSlot = SourceSlot(SystemInfoCollector())
    }

    // MARK: Control

    public func start() {
        queue.async { [self] in
            guard !isRunning else { return }
            isRunning = true
            registerPowerNotificationLocked()
            rescheduleTimerLocked()
            sampleLocked()
        }
    }

    public func stop() {
        queue.async { [self] in
            isRunning = false
            timer?.cancel()
            timer = nil
            if powerNotifyToken != NOTIFY_TOKEN_INVALID {
                notify_cancel(powerNotifyToken)
                powerNotifyToken = NOTIFY_TOKEN_INVALID
            }
            forEachSlot { $0.shutdown() }
        }
    }

    public func apply(_ configuration: Configuration) {
        queue.async { [self] in
            applyLocked(configuration)
        }
    }

    public func setActivity(_ newActivity: SamplingActivity) {
        queue.async { [self] in
            guard newActivity != activity else { return }
            let wasSuspended = !activity.isSampling
            activity = newActivity
            // The panel and the widget always get the full rate; quiet is re-earned
            // from the next sample once only the menu bar is left.
            if newActivity != .menuBar { isQuiet = false; isSteady = false; steadyRun = 0 }
            rescheduleTimerLocked()
            // Coming back from suspension, sample immediately so the user never
            // sees a stale menu bar after unlocking the screen.
            if wasSuspended && newActivity.isSampling {
                forEachSlot {
                    $0.invalidateBaseline()
                    $0.resetRetry()
                }
                pendingWakeFlag = true
                sampleLocked(force: true)
            } else if newActivity > .menuBar {
                // The panel or widget just opened: this is the one immediate sample
                // for that surface, so it ignores cadence. Only one: two back-to-back
                // passes give the counter collectors a near-zero interval to divide by.
                sampleLocked(force: true)
            }
        }
    }

    /// The set of collectors anything on screen actually needs. Sources outside
    /// this set are never sampled and release their resources.
    public func setEnabledSources(_ sources: Set<CollectorID>) {
        queue.async { [self] in
            guard sources != enabledSources else { return }
            let removed = enabledSources.subtracting(sources)
            enabledSources = sources
            forEachSlot { slot in
                if removed.contains(slot.identifier) { slot.suspend() }
            }
            if isRunning { sampleLocked() }
        }
    }

    /// Turns the public IP lookup on or off. The one collector behaviour the user has
    /// to opt into, so it is pushed down here rather than read from settings by the
    /// collector: this queue is the only place a collector's state may be touched.
    public func setPublicIPLookupEnabled(_ enabled: Bool) {
        queue.async { [self] in
            publicIPLookupEnabled = enabled
            networkSlot.source.setPublicIPLookupEnabled(enabled)
        }
    }

    /// The latency probe exists for the panel's network module, so it follows panel
    /// visibility rather than a setting: opening the panel starts it, closing it
    /// stops the traffic entirely.
    public func setLatencyProbeEnabled(_ enabled: Bool) {
        queue.async { [self] in
            networkSlot.source.setLatencyProbeEnabled(enabled)
        }
    }

    public func triggerLatencyProbe() {
        queue.async { [self] in
            networkSlot.source.triggerLatencyProbe()
        }
    }

    /// Called on wake from sleep: cumulative counters may have reset and every
    /// rate is meaningless until re-baselined.
    public func noteWakeFromSleep() {
        queue.async { [self] in
            pendingWakeFlag = true
            forEachSlot {
                $0.invalidateBaseline()
                $0.resetRetry()
            }
        }
    }

    /// Thermal pressure slows expensive optional reads while retaining every selected
    /// source. Recovery samples immediately so the UI does not stay stale after the
    /// system returns to a nominal state.
    public func setThermalPressure(_ pressure: ThermalPressure) {
        queue.async { [self] in
            let multiplier: Double
            switch pressure {
            case .nominal, .fair: multiplier = 1
            case .serious: multiplier = 3
            case .critical: multiplier = 5
            }
            guard multiplier != thermalCadenceMultiplier else { return }
            let wasConstrained = thermalCadenceMultiplier > 1
            thermalCadenceMultiplier = multiplier
            if wasConstrained, multiplier == 1, isRunning, activity.isSampling {
                sampleLocked(force: true)
            }
        }
    }

    // MARK: Internals

    private func registerPowerNotificationLocked() {
        guard powerNotifyToken == NOTIFY_TOKEN_INVALID else { return }
        var token = NOTIFY_TOKEN_INVALID
        let status = notify_register_dispatch(kIOPSNotifyPowerSource, &token, queue) { [weak self] _ in
            self?.powerEventPending = true
        }
        // A failed registration leaves the battery on its old five-second poll, which
        // is the behaviour it had before there were events at all.
        if status == NOTIFY_STATUS_OK { powerNotifyToken = token }
    }

    private func forEachSlot(_ body: (any SlotErasing) -> Void) {
        body(cpuSlot); body(memorySlot); body(gpuSlot); body(networkSlot)
        body(diskSlot); body(powerSlot); body(thermalSlot); body(processSlot)
        body(systemSlot)
    }

    private func rescheduleTimerLocked() {
        timer?.cancel()
        timer = nil
        guard isRunning, activity.isSampling else { return }

        let interval = baseInterval * activity.cadenceMultiplier
            * (isSteady ? Self.steadyCadenceMultiplier : (isQuiet ? Self.quietCadenceMultiplier : 1))
        let t = DispatchSource.makeTimerSource(queue: queue)
        // Generous leeway lets the kernel coalesce our wakeups with other timers.
        // This is the difference between "Very Low" and "Low" energy impact.
        let leeway = max(0.1, interval * 0.25)
        t.schedule(deadline: .now() + interval, repeating: interval, leeway: .milliseconds(Int(leeway * 1000)))
        t.setEventHandler { [weak self] in self?.sampleLocked() }
        t.resume()
        timer = t
    }

    private func applyLocked(_ configuration: Configuration) {
        let clamped = min(max(configuration.baseInterval, 0.5), 60)
        let removed = enabledSources.subtracting(configuration.enabledSources)
        let sourcesChanged = configuration.enabledSources != enabledSources
        let intervalChanged = clamped != baseInterval
        let publicIPChanged = configuration.publicIPLookupEnabled != publicIPLookupEnabled

        baseInterval = clamped
        enabledSources = configuration.enabledSources
        publicIPLookupEnabled = configuration.publicIPLookupEnabled
        forEachSlot { slot in
            if removed.contains(slot.identifier) { slot.suspend() }
        }
        if publicIPChanged {
            networkSlot.source.setPublicIPLookupEnabled(configuration.publicIPLookupEnabled)
        }
        if intervalChanged { rescheduleTimerLocked() }
        if isRunning && (sourcesChanged || intervalChanged || publicIPChanged) { sampleLocked() }
    }

    private func sampleLocked(force: Bool = false) {
        let now = Monotonic.now
        let didWake = pendingWakeFlag
        pendingWakeFlag = false

        var changed = false
        func run<S: MetricSource>(_ slot: SourceSlot<S>) {
            var multiplier = thermalMultiplier(for: slot.identifier)
            if slot.identifier == .thermal, activity < .desktopWidget {
                multiplier *= Self.thermalMenuBarMultiplier
            }
            // Processes are expensive. While the panel is open on an idle machine (< 6% CPU),
            // double the process cadence to avoid spending cycles re-enumerating idle PIDs.
            if slot.identifier == .processes, activity >= .panel {
                if let busy = cpuSlot.state.value?.total.busy, busy < 0.06 {
                    multiplier *= 2.0
                }
            }
            var forced = force
            if slot.identifier == .power {
                forced = forced || powerEventPending
                if powerNotifyToken != NOTIFY_TOKEN_INVALID, activity < .desktopWidget {
                    multiplier *= Self.powerIdleCadenceMultiplier
                }
            }
            if slot.tick(now: now,
                         activity: activity,
                         isEnabled: enabledSources.contains(slot.identifier),
                         baseInterval: baseInterval,
                         didWakeFromSleep: didWake,
                         force: forced,
                         thermalCadenceMultiplier: multiplier) {
                changed = true
            }
        }

        run(systemSlot)
        run(cpuSlot)
        run(memorySlot)
        run(gpuSlot)
        run(networkSlot)
        run(diskSlot)
        run(powerSlot)
        powerEventPending = false
        updateQuietLocked()
        run(thermalSlot)
        // Processes are by far the most expensive source; only ever sampled when
        // the panel that displays them is actually on screen, or twice in a minute
        // the day chart will have to explain.
        if activity >= .panel {
            run(processSlot)
        } else if wantsPeakWitness() {
            run(processSlot)
        }

        guard changed else { return }

        let snapshot = SystemSnapshot(
            cpu: cpuSlot.state,
            memory: memorySlot.state,
            gpu: gpuSlot.state,
            network: networkSlot.state,
            disk: diskSlot.state,
            power: powerSlot.state,
            thermal: thermalSlot.state,
            processes: processSlot.state,
            processesSampled: processSlot.sampled(at: now),
            system: systemSlot.state,
            capturedAt: Date(),
            capturedInstant: now
        )

        let callback = onSnapshot
        DispatchQueue.main.async { MainActor.assumeIsolated { callback(snapshot) } }
    }

    /// Enters or leaves the quiet cadence from the CPU sample just taken. Only the
    /// menu-bar-only activity can be quiet: the panel and the widget are being looked
    /// at, and an occluded bar is already slowed further. Without a CPU reading the
    /// session is never quiet, since there is nothing to say it is idle.
    private func updateQuietLocked() {
        let busy = cpuSlot.state.value?.total.busy
        let quiet = Self.isQuiet(activity: activity, busy: busy, wasQuiet: isQuiet)
        if let busy, let last = lastBusy, quiet, abs(busy - last) < Self.steadyBand {
            steadyRun += 1
        } else {
            steadyRun = 0
        }
        lastBusy = busy
        let steady = quiet && steadyRun >= Self.steadySamples
        guard quiet != isQuiet || steady != isSteady else { return }
        isQuiet = quiet
        isSteady = steady
        rescheduleTimerLocked()
    }

    static func isQuiet(activity: SamplingActivity, busy: Double?, wasQuiet: Bool) -> Bool {
        guard activity == .menuBar, let busy else { return false }
        return busy < (wasQuiet ? quietExitBusy : quietEnterBusy)
    }

    /// Whether this tick should read the process list to name what is behind a
    /// peak. A minute whose CPU or memory pressure clears the threshold gets two
    /// reads: the first rebaselines the per-process counters and reports nothing,
    /// the second, a tick later, carries real percentages over that tick. One pair
    /// per minute at most, so a sustained load costs two reads a minute and an idle
    /// machine costs none.
    private func wantsPeakWitness() -> Bool {
        if witnessFollowUpDue {
            witnessFollowUpDue = false
            return true
        }
        if witnessRequested {
            witnessRequested = false
            processSlot.invalidateBaseline()
            witnessFollowUpDue = true
            return true
        }
        let busy = cpuSlot.state.value?.total.busy ?? 0
        let pressure = memorySlot.state.value?.pressureFraction ?? 0
        // One core flat out is a tenth of a twelve-core Mac but less than that of a
        // larger one, and a single runaway core is exactly what the runaway alert
        // looks for, so the bar is the lower of the two.
        let cores = Double(max(cpuSlot.state.value?.perCore.count ?? 1, 1))
        let cpuBar = min(Self.cpuWitnessThreshold, Self.oneCoreShare / cores)
        guard busy >= cpuBar || pressure >= Self.memoryWitnessThreshold else {
            return false
        }
        let minute = Int(Date().timeIntervalSince1970 / 60)
        guard minute != witnessedMinute else { return false }
        witnessedMinute = minute
        // Counters last read minutes or hours ago would rank processes by their
        // average since then, not by what they are doing now.
        processSlot.invalidateBaseline()
        witnessFollowUpDue = true
        return true
    }

    /// Reads the process list on the next two ticks, whatever the load.
    func requestProcessWitness() {
        queue.async { [weak self] in self?.witnessRequested = true }
    }

    private func thermalMultiplier(for identifier: CollectorID) -> Double {

        switch identifier {
        case .gpu, .disk, .processes: return thermalCadenceMultiplier
        default: return 1
        }
    }
}

/// Type-erased slot operations that do not depend on the source's `Output`.
protocol SlotErasing: AnyObject {
    var identifier: CollectorID { get }
    func suspend()
    func invalidateBaseline()
    func resetRetry()
    func shutdown()
}

extension SourceSlot: SlotErasing {}
