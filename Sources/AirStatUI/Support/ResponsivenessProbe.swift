import Foundation
import AirStatKit

/// The system's own link-quality test, run on demand.
///
/// `/usr/bin/networkQuality` is the binary behind "Responsiveness" in Wireless
/// Diagnostics: it saturates the link for about twenty seconds and reports the
/// round-trips-per-minute a loaded connection still manages — the number a fast
/// but bufferbloated link fails on. Because the test itself is the congestion, it
/// runs only when asked: a row in the open panel is the only place it can start
/// from, and nothing fires it on a timer.
@MainActor
final class ResponsivenessProbe: ObservableObject {

    enum State: Equatable {
        case idle
        case running
        case done(responsiveness: String, downloadMbps: Double?, uploadMbps: Double?)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// Retained so `cancel()` can actually stop the measurement — a cancelled task
    /// alone would leave the test saturating the link for a result nobody sees.
    private var process: Process?

    /// Whether a run may start. Re-tapping while a measurement is in flight is a
    /// no-op rather than a second saturating test.
    var canRun: Bool {
        if case .running = state { return false }
        return true
    }

    func run() {
        guard canRun else { return }
        state = .running

        let process = Process()
        process.executableURL = URL(fileURLWithPath: Self.binary)
        // -s is the summary run: uplink and downlink together, ~20 s.
        process.arguments = ["-s"]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        process.terminationHandler = { [weak self] _ in
            let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(),
                              as: UTF8.self)
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.process = nil
                guard case .running = self.state else { return }
                self.state = Self.interpret(text)
            }
        }
        do {
            try process.run()
            self.process = process
        } catch {
            state = .failed("networkQuality could not start")
        }
    }

    func cancel() {
        process?.terminate()
        process = nil
        state = .idle
    }

    // MARK: Measurement

    private static let binary = "/usr/bin/networkQuality"

    /// The three numbers worth keeping from the summary block: the RPM verdict,
    /// and each direction's capacity. Anything unparseable degrades to its own
    /// "unavailable" rather than a fabricated figure.
    static func interpret(_ output: String) -> State {
        var responsiveness: String?
        var download: Double?, upload: Double?
        for line in output.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Responsiveness:"), responsiveness == nil {
                responsiveness = String(trimmed.dropFirst("Responsiveness:".count))
                    .trimmingCharacters(in: .whitespaces)
            } else if trimmed.hasPrefix("Download capacity:") {
                download = number(in: trimmed)
            } else if trimmed.hasPrefix("Upload capacity:") {
                upload = number(in: trimmed)
            }
        }
        guard let responsiveness, !responsiveness.isEmpty else {
            return .failed(output.isEmpty ? "the test produced no summary"
                                          : "the summary was not recognised")
        }
        return .done(responsiveness: responsiveness, downloadMbps: download,
                     uploadMbps: upload)
    }

    /// "1,432.220 Mbps" → 1432.220; the locale-safe read of the summary's figures.
    private static func number(in line: String) -> Double? {
        guard let match = line.range(of: #"[\d,]+(\.\d+)?(?=\s*Mbps)"#,
                                     options: .regularExpression) else { return nil }
        return Double(line[match].replacingOccurrences(of: ",", with: ""))
    }
}
