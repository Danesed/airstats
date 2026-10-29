import Foundation
import AppKit
import UserNotifications
import MuStatsKit

/// Watches metrics against the user's threshold rules and posts notifications.
///
/// Sustained-duration and cooldown handling live here so a transient spike while
/// launching an app never produces an alert.
@MainActor
public final class ThresholdMonitor {

    private let engine: MetricsEngine
    private let settings: SettingsStore
    private let authority: NotificationAuthority

    private var observationTask: Task<Void, Never>?
    private var evaluator = ThresholdEvaluator()
    /// The last public IP actually reported, or nil until the first lookup lands.
    /// Seeded silently rather than alerted on, because an address read for the first
    /// time cannot be told apart from one that changed while nobody was watching.
    private var lastSeenPublicIP: String?
    /// Same seeding rule as the IP: the link state read on the first sample after
    /// launch is the baseline, not an event.
    private var lastSeenConnectivity: Bool?
    private var runaway = RunawayWatch()
    private var unusual = UnusualWatch()
    private var unplug = UnplugWatch()

    /// True while the observation loop and any pending authorisation request are
    /// installed.
    ///
    /// Exposed for the same reason `PanelController.activeEventMonitorCount` is: a
    /// task or a delegate that outlives `stop()` is silent, and nothing looks wrong
    /// until the app is posting notifications on behalf of a shut-down monitor.
    public var isRunning: Bool {
        observationTask != nil || authority.isRunning
    }

    /// The authority is injected rather than defaulted so that anything else which
    /// starts posting shares this one: a default would quietly give each poster its
    /// own, which is a second permission prompt and a fight over the delegate slot.
    public init(engine: MetricsEngine, settings: SettingsStore,
                authority: NotificationAuthority) {
        self.engine = engine
        self.settings = settings
        self.authority = authority
    }

    // MARK: Lifecycle

    public func start() {
        guard observationTask == nil else { return }
        authority.onAction { [weak self] action, info in self?.handle(action, info) }
        // Observation-driven like the status item rather than a timer of its own: the
        // rules can only ever change answer when a new snapshot or a new setting lands.
        // The tracking closure below is rebuilt when the feature toggles so a disabled
        // monitor keeps only the settings wakeup and never follows the sample stream.
        observationTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let notificationsEnabled = self.settings.settings.notifications.isEnabled
                let changes = ObservedChanges { [engine = self.engine, settings = self.settings] in
                    _ = settings.revision
                    if settings.settings.notifications.isEnabled {
                        _ = engine.snapshot
                    }
                }
                self.evaluate()

                for await _ in changes {
                    guard !Task.isCancelled else { return }
                    self.evaluate()
                    guard self.settings.settings.notifications.isEnabled == notificationsEnabled else {
                        break
                    }
                }
            }
        }
    }

    public func stop() {
        observationTask?.cancel()
        observationTask = nil
        evaluator.reset()
        authority.reset()
    }

    // MARK: Evaluation

    private func evaluate() {
        let notifications = settings.settings.notifications
        guard notifications.isEnabled else {
            evaluator.reset()
            lastSeenPublicIP = nil
            lastSeenConnectivity = nil
            return
        }
        // Nothing is measured until there is somewhere to send the answer. Denial is
        // terminal, so a refused prompt costs one check per sample and no more.
        //
        // Asked here, the first time the user actually switches notifications on, and
        // never at launch. A menu bar utility that demands permission on first run is
        // asking for something the user has not opted into yet.
        guard authority.request("threshold alerts") else { return }

        // A rule for a metric this Mac cannot measure could never fire honestly, and
        // the pane already tells the user so.
        let availability = MetricAvailability(snapshot: engine.snapshot)
        let rules = notifications.enabledRules.filter { availability.note(for: $0.metric) == nil }

        let alerts = evaluator.alerts(for: rules,
                                      readings: ThresholdEvaluator.readings(from: engine.snapshot),
                                      now: Date())
        for alert in alerts { deliver(alert) }

        // The public IP watch is an edge, not a level, so it sits beside the rule
        // evaluator rather than inside it. A failed lookup is simply not a new
        // address: the baseline stays, so a VPN dropping and coming back to the
        // same exit alerts nothing.
        if notifications.notifiesOnPublicIPChange,
           let current = engine.snapshot.network.value?.publicIP.value {
            if let last = lastSeenPublicIP, last != current {
                authority.post(identifier: "network.publicIP",
                               title: String(localized: "Public IP changed"),
                               body: String(localized: "Now \(current), previously \(last)."))
                WindowLog.log("notification posted metric=publicIP value=\(current) previous=\(last)")
            }
            lastSeenPublicIP = current
        }

        // Connectivity is the other edge: the link type is already in the snapshot,
        // so watching it costs a compare. Only the boundary matters — Wi-Fi to
        // Ethernet is still online, and the first sample after launch is seeded.
        if notifications.notifiesOnConnectivityChange,
           let network = engine.snapshot.network.value {
            let online = network.connectionType != .none
            if let last = lastSeenConnectivity, last != online {
                authority.post(identifier: "network.connectivity",
                               title: online ? String(localized: "Back online") : String(localized: "Internet connection lost"),
                               body: online ? String(localized: "\(network.connectionType.label) is connected again.")
                                            : String(localized: "The primary interface is down."))
                WindowLog.log("notification posted metric=connectivity online=\(online)")
            }
            lastSeenConnectivity = online
        }

        evaluateSmart(notifications)
    }

    /// The alerts worked out from the Mac rather than from a rule: a runaway, the
    /// unusual, a heavy app at unplugging. Each watch keeps its own state and its own
    /// cooldown, and none of them reads anything the engine does not already hold.
    private func evaluateSmart(_ notifications: NotificationSettings) {
        let snapshot = engine.snapshot
        let now = Date()
        let formatter = MetricFormatter(settings: settings.settings.general)
        // Only a list read this tick: a stale one would keep a streak alive that ended.
        let fresh = snapshot.processesSampled ? snapshot.processes.value?.processes : nil
        let own = ProcessInfo.processInfo.processIdentifier

        if notifications.notifiesOnRunaway, let fresh,
           let alert = runaway.update(processes: fresh, ownPID: own, idle: UserIdle.seconds(),
                                      ignored: Set(notifications.ignoredRunaways), now: now) {
            deliver(alert)
        }
        if notifications.notifiesOnUnusual {
            for alert in unusual.update(day: engine.dayHistory, month: engine.monthHistory,
                                        formatter: formatter, now: now) {
                deliver(alert)
            }
        }
        if notifications.notifiesOnHeavyUnplug {
            let outcome = unplug.update(power: snapshot.power.value, processes: fresh, ownPID: own,
                                        formatter: formatter, now: now)
            if outcome.requestsWitness { engine.requestProcessWitness() }
            if let alert = outcome.alert { deliver(alert) }
        }
    }

    // MARK: Delivery

    private func deliver(_ alert: SmartAlert) {
        var info: [AnyHashable: Any] = [:]
        if let pid = alert.pid { info["pid"] = Int(pid) }
        if let name = alert.processName { info["name"] = name }
        authority.post(identifier: alert.identifier, title: alert.title, body: alert.body,
                       category: alert.category == .plain ? nil : alert.category.rawValue,
                       userInfo: info)
        WindowLog.log("notification posted smart=\(alert.identifier)")
    }

    /// Quit asks the process to quit, after checking the pid still belongs to it: a
    /// notification read an hour later may name a pid the system has since reused.
    /// Ignore remembers the name so the runaway watch stops warning about it.
    private func handle(_ action: String, _ info: [AnyHashable: Any]) {
        guard let name = info["name"] as? String else { return }
        switch action {
        case NotificationAuthority.quitAction:
            guard let pid = (info["pid"] as? Int).map(Int32.init), ProcessName.of(pid) == name else { return }
            if let app = NSRunningApplication(processIdentifier: pid) {
                app.terminate()
            } else {
                kill(pid, SIGTERM)
            }
        case NotificationAuthority.ignoreAction:
            settings.update { s in
                if !s.notifications.ignoredRunaways.contains(name) {
                    s.notifications.ignoredRunaways.append(name)
                }
            }
        default:
            break
        }
    }

    private func deliver(_ alert: ThresholdAlert) {
        // One identifier per rule, so a rule that fires again after its cooldown
        // replaces its own stale banner instead of stacking a column of the same
        // warning in Notification Centre.
        authority.post(identifier: "threshold.\(alert.ruleID.uuidString)",
                       title: alert.title,
                       body: alert.body)
        WindowLog.log("notification posted metric=\(alert.metric.rawValue) value=\(alert.value) threshold=\(alert.threshold)")
    }
}
