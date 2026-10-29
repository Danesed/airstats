import Foundation
import IOKit.pwr_mgt

/// A process holding the Mac awake, read from the power manager's own list.
public struct SleepBlocker: Sendable, Equatable, Identifiable {
    public enum Hold: Int, Sendable, Comparable {
        /// Keeps the screen on, which keeps the Mac awake with it.
        case display
        /// Lets the screen sleep but not the Mac.
        case system

        public static func < (a: Hold, b: Hold) -> Bool { a.rawValue < b.rawValue }
    }

    public var pid: Int32
    public var processName: String
    public var hold: Hold
    /// What the process said it is doing, in its own words: "Playing audio",
    /// "caffeinate command-line tool". Empty when it said nothing useful.
    public var reason: String

    public var id: Int32 { pid }

    public init(pid: Int32, processName: String, hold: Hold, reason: String) {
        self.pid = pid
        self.processName = processName
        self.hold = hold
        self.reason = reason
    }
}

/// Who is keeping the Mac from sleeping, one entry per process.
///
/// Read on demand, when someone opens the panel to ask: one call into powerd, no
/// polling while nobody is looking.
public enum SleepBlockers {

    /// Assertion types that stop the Mac, or its display, from going to sleep.
    static let holds: [String: SleepBlocker.Hold] = [
        "PreventUserIdleSystemSleep": .system,
        "PreventSystemSleep": .system,
        "NoIdleSleepAssertion": .system,
        "PreventUserIdleDisplaySleep": .display,
        "NoDisplaySleepAssertion": .display,
    ]

    /// Holds the system takes on its own behalf while the display is on, which are
    /// the display being on rather than anything keeping it there.
    static let ignoredProcesses: Set<String> = ["powerd", "WindowServer"]

    public static func current() -> [SleepBlocker] {
        var raw: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess,
              let byProcess = raw?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        return blockers(from: byProcess.map { ($0.key.int32Value, $0.value) })
    }

    /// The parsing, apart from the call, so it can be tested on a fixed list.
    static func blockers(from byProcess: [(pid: Int32, assertions: [[String: Any]])]) -> [SleepBlocker] {
        var result: [SleepBlocker] = []
        for (pid, assertions) in byProcess {
            var strongest: SleepBlocker?
            for assertion in assertions {
                guard let type = assertion["AssertType"] as? String, let hold = holds[type],
                      (assertion["AssertLevel"] as? Int ?? 255) > 0 else { continue }
                let name = assertion["Process Name"] as? String ?? ""
                guard !name.isEmpty, !ignoredProcesses.contains(name) else { continue }
                let reason = (assertion["HumanReadableReason"] as? String)
                    ?? (assertion["AssertName"] as? String) ?? ""
                let blocker = SleepBlocker(pid: pid, processName: name, hold: hold,
                                           reason: readable(reason, processName: name))
                if strongest.map({ blocker.hold > $0.hold }) ?? true { strongest = blocker }
            }
            if let strongest { result.append(strongest) }
        }
        return result.sorted { ($0.hold, $1.processName) > ($1.hold, $0.processName) }
    }

    /// An assertion name is often an identifier ("BTLEAdvertisement.5832B539-…",
    /// "com.apple.something") or just the process's own name again. Those say nothing
    /// a person can use, so they are dropped rather than printed.
    static func readable(_ reason: String, processName: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || trimmed == processName { return "" }
        if trimmed.contains(".") && !trimmed.contains(" ") { return "" }
        if trimmed.range(of: #"[0-9A-F]{8}-[0-9A-F]{4}"#, options: .regularExpression) != nil { return "" }
        return trimmed
    }
}
