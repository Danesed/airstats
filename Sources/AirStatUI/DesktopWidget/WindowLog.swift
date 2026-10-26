import Foundation

/// Opt-in tracing for window behaviour.
///
/// Window bugs — a panel that drifts off screen, an event monitor that is installed
/// twice and removed once — are invisible in a screenshot and awkward to reproduce by
/// hand. This lets a run of the real app narrate what its windows are doing:
///
///     AIRSTAT_WINDOW_LOG=1 open -a AirStat.app   # or run the binary directly
///
/// Off by default and reduced to a single boolean check when disabled, so it costs
/// nothing in a normal session.
enum WindowLog {
    static let isEnabled = ProcessInfo.processInfo.environment["AIRSTAT_WINDOW_LOG"] == "1"

    /// Mirror of the trace when the app was launched through `open`/Finder, where
    /// stderr has no reader. Appended, never truncated, and only ever in /tmp.
    private static let mirrorURL = URL(fileURLWithPath: "/tmp/airstat-window.log")

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let line = "[airstat.window] \(message())\n"
        FileHandle.standardError.write(Data(line.utf8))
        if let handle = try? FileHandle(forWritingTo: mirrorURL) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            try? handle.close()
        } else {
            try? Data(line.utf8).write(to: mirrorURL)
        }
    }
}
