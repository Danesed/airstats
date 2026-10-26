import Foundation

/// How much traffic passed, attributed to a day and to a named network.
///
/// The kernel counters (`totalUploadBytes`/`totalDownloadBytes`) count since boot,
/// so a delta between any two samples covers the whole gap between them — sampling
/// pauses lose nothing. Only uptime zeroes them, which is why a decreasing counter
/// means a reboot and the baseline re-anchors rather than going negative.
///
/// Two questions are answered here, cheaply enough that they were worth a file and
/// a few hundred bytes of JSON rather than a database: "how much today" and "how
/// much on this network" — the second is what a phone-hotspot or hotel Wi-Fi user
/// actually wants to know.
public struct NetworkUsageLedger: Codable, Sendable, Equatable {

    public struct Totals: Codable, Sendable, Equatable {
        public var upload: UInt64 = 0
        public var download: UInt64 = 0

        /// Bytes the connection type cannot carry: a delta larger than this means
        /// the kernel counters reset (a reboot), and adding it would attribute a
        /// whole uptime's worth of traffic to today.
        public static let sanityCeiling: UInt64 = 1 << 50 // 1 PiB

        public mutating func add(upload up: UInt64, download down: UInt64) {
            upload += up
            download += down
        }

        public func combined() -> UInt64 { upload + download }
    }

    /// ISO day key ("2026-10-26") the `today` totals belong to; a new key means a
    /// new day and the totals start over rather than a "last 24 h" that drifts.
    public var dayKey: String = ""
    public var today = Totals()
    /// Cumulative bytes per network name (the Wi-Fi SSID, or the interface name
    /// where there is no SSID). All-time, because a cap reads over months.
    public var networks: [String: Totals] = [:]

    /// The counters last seen, so each observation attributes only what is new.
    /// Not persisted on purpose: after a relaunch the first sample re-baselines,
    /// which drops whatever flowed while the app was off — the honest amount,
    /// since bytes moved unobserved cannot be attributed to a network.
    public private(set) var lastUpload: UInt64?
    public private(set) var lastDownload: UInt64?

    private enum CodingKeys: String, CodingKey { case dayKey, today, networks }

    public init() {}

    /// Names the current network the way the totals file does: SSID when there is
    /// one, else the interface ("en0" is less readable than "Ethernet").
    public static func networkName(of snapshot: NetworkSnapshot) -> String? {
        if let ssid = snapshot.wifi?.ssid, !ssid.isEmpty { return ssid }
        guard snapshot.connectionType != .none else { return nil }
        return snapshot.connectionType == .wifi ? snapshot.primaryInterfaceName
                                                : snapshot.connectionType.label
    }

    /// Attributes the bytes moved since the previous observation. Called once per
    /// snapshot on the engine's ingest path.
    public mutating func observe(_ snapshot: NetworkSnapshot, at date: Date) {
        defer {
            lastUpload = snapshot.totalUploadBytes
            lastDownload = snapshot.totalDownloadBytes
        }
        guard let lastUpload, let lastDownload,
              snapshot.totalUploadBytes >= lastUpload,
              snapshot.totalDownloadBytes >= lastDownload else { return }
        let up = snapshot.totalUploadBytes - lastUpload
        let down = snapshot.totalDownloadBytes - lastDownload
        guard up < Totals.sanityCeiling, down < Totals.sanityCeiling,
              up > 0 || down > 0 else { return }

        let key = Self.dayFormatter.string(from: date)
        if key != dayKey {
            dayKey = key
            today = Totals()
        }
        today.add(upload: up, download: down)
        if let name = Self.networkName(of: snapshot) {
            networks[name, default: Totals()].add(upload: up, download: down)
        }
    }

    private static let dayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()
}

/// The ledger's JSON file, saved debounced and on stop next to the history files.
public struct NetworkUsageFile: Sendable {
    private let url: URL

    public init(directory: URL, name: String = "network-usage.json") {
        url = directory.appendingPathComponent(name)
    }

    public func load() -> NetworkUsageLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(NetworkUsageLedger.self, from: data)
        else { return NetworkUsageLedger() }
        return ledger
    }

    public func save(_ ledger: NetworkUsageLedger) {
        guard let data = try? JSONEncoder().encode(ledger) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
