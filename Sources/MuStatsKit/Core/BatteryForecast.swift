import Foundation

/// Battery life said in minutes rather than watts: how long the charge left will
/// last, and how much longer it would last without one process.
///
/// A watt figure answers a question nobody asks. "Quitting Docker gives you 1 h 10 min"
/// is the same number turned into the thing a person on battery is deciding about.
public enum BatteryForecast {

    /// The pack's draw while it is discharging, in watts, or nil on power or with no
    /// reading. `batteryWatts` is volts times amps, negative on the way out.
    public static func draw(_ power: PowerSnapshot) -> Double? {
        guard power.hasBattery, !power.isPluggedIn, let watts = power.batteryWatts, watts < 0 else { return nil }
        return -watts
    }

    /// Seconds left at the present draw. The system's own estimate when it has one;
    /// otherwise the charge left in watt-hours over the draw, which is what the
    /// system is still averaging towards for the first minute after unplugging.
    public static func timeLeft(_ power: PowerSnapshot) -> TimeInterval? {
        if let toEmpty = power.timeToEmpty, toEmpty > 0 { return toEmpty }
        guard let draw = draw(power), draw > 0,
              let milliampHours = power.currentCapacitymAh, milliampHours > 0,
              let volts = power.voltage, volts > 0 else { return nil }
        return Double(milliampHours) * volts / 1000 / draw * 3600
    }

    /// The share of the draw a process can be said to free when it quits. Never all
    /// of it: the display, the radios and the rest of the system keep drawing, and
    /// the kernel's per-process energy is an estimate that can overshoot the pack's.
    static let removableShare = 0.75

    /// How much longer the battery would last without a process drawing
    /// `processWatts`, or nil when that is not worth saying.
    ///
    /// The energy left is the same either way, so the time scales with the draw:
    /// left × draw / (draw − process).
    public static func gain(timeLeft: TimeInterval, draw: Double, processWatts: Double) -> TimeInterval? {
        guard timeLeft > 0, draw > 0, processWatts > 0 else { return nil }
        let freed = min(processWatts, draw * removableShare)
        return timeLeft * draw / (draw - freed) - timeLeft
    }

    /// Ten minutes: below that the gain is inside the estimate's own wobble.
    public static let worthSaying: TimeInterval = 600
}
