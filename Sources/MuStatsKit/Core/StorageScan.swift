import Foundation

/// A folder that tends to grow without anyone noticing, with what it measured at
/// over the last week.
public struct StorageFolder: Codable, Sendable, Equatable, Identifiable {
    public struct Sample: Codable, Sendable, Equatable {
        public var date: Date
        public var bytes: UInt64

        public init(date: Date, bytes: UInt64) {
            self.date = date
            self.bytes = bytes
        }
    }

    public var id: String
    public var label: String
    public var path: String
    /// Safe to empty: the owner rebuilds it on its own the next time it is needed.
    public var isCleanable: Bool
    /// Oldest first. One kept per twelve hours, a week of them at most.
    public var samples: [Sample]

    public var bytes: UInt64? { samples.last?.bytes }

    /// The change since the sample closest to a day before the newest, at least
    /// twelve hours older than it, with that sample's date. Nil until there is one.
    public var change: (bytes: Int64, since: Date)? {
        guard let newest = samples.last else { return nil }
        let earlier = samples.dropLast().filter { newest.date.timeIntervalSince($0.date) >= 12 * 3_600 }
        guard let base = earlier.min(by: {
            abs(newest.date.timeIntervalSince($0.date) - 86_400) < abs(newest.date.timeIntervalSince($1.date) - 86_400)
        }) else { return nil }
        return (Int64(newest.bytes) - Int64(base.bytes), base.date)
    }
}

/// Where the space went: a handful of folders known to grow, measured rarely.
///
/// Measured when someone opens the disk module and the last measurement is more than
/// six hours old, at background priority, and stopped if they close it. Only folders
/// outside the ones macOS asks permission for: nothing here can put up a prompt.
public enum StorageScan {

    struct Candidate {
        let id: String
        let label: String
        let path: String
        let isCleanable: Bool
    }

    static var candidates: [Candidate] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            Candidate(id: "derivedData", label: "Xcode build data",
                      path: home + "/Library/Developer/Xcode/DerivedData", isCleanable: true),
            Candidate(id: "simulators", label: "Simulators",
                      path: home + "/Library/Developer/CoreSimulator/Devices", isCleanable: false),
            Candidate(id: "deviceSupport", label: "Device support files",
                      path: home + "/Library/Developer/Xcode/iOS DeviceSupport", isCleanable: false),
            Candidate(id: "archives", label: "Xcode archives",
                      path: home + "/Library/Developer/Xcode/Archives", isCleanable: false),
            Candidate(id: "caches", label: "App caches", path: home + "/Library/Caches", isCleanable: false),
            Candidate(id: "npm", label: "npm cache", path: home + "/.npm", isCleanable: false),
            Candidate(id: "dotCache", label: "Tool caches (~/.cache)", path: home + "/.cache", isCleanable: false),
            Candidate(id: "gradle", label: "Gradle", path: home + "/.gradle", isCleanable: false),
            Candidate(id: "cargo", label: "Cargo", path: home + "/.cargo", isCleanable: false),
        ]
    }

    /// Below this a folder is not worth a row.
    public static let worthListing: UInt64 = 500_000_000
    /// How old the last measurement has to be before opening the module measures again.
    public static let staleAfter: TimeInterval = 6 * 3_600

    /// Measures every candidate that exists and folds the result into `previous`.
    /// Returns nil if cancelled part way, so a half-measured folder is never saved.
    public static func scan(previous: [StorageFolder], now: Date = Date(),
                            isCancelled: () -> Bool) -> [StorageFolder]? {
        var result: [StorageFolder] = []
        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            guard let bytes = measure(URL(fileURLWithPath: candidate.path), isCancelled: isCancelled) else { return nil }
            var folder = previous.first { $0.id == candidate.id }
                ?? StorageFolder(id: candidate.id, label: candidate.label, path: candidate.path,
                                 isCleanable: candidate.isCleanable, samples: [])
            folder.label = candidate.label
            folder.samples = fold(folder.samples, StorageFolder.Sample(date: now, bytes: bytes))
            result.append(folder)
        }
        return result
    }

    /// The newest sample replaces one taken in the last twelve hours, so the list
    /// holds a reading per half day; anything over a week old drops off.
    public static func fold(_ samples: [StorageFolder.Sample], _ new: StorageFolder.Sample) -> [StorageFolder.Sample] {
        var kept = samples.filter { new.date.timeIntervalSince($0.date) <= 7 * 86_400 }
        if let last = kept.last, new.date.timeIntervalSince(last.date) < 12 * 3_600 {
            kept.removeLast()
        }
        kept.append(new)
        return kept
    }

    /// Bytes the folder takes on disk, counting what is allocated rather than the
    /// files' lengths, so a sparse disk image counts what it really holds.
    public static func measure(_ url: URL, isCancelled: () -> Bool) -> UInt64? {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey, .isRegularFileKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                          options: [], errorHandler: { _, _ in true })
        else { return 0 }
        var total: UInt64 = 0
        var seen = 0
        for case let file as URL in walker {
            seen += 1
            if seen % 2_000 == 0, isCancelled() { return nil }
            guard let values = try? file.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            total += UInt64(values.totalFileAllocatedSize ?? 0)
        }
        return total
    }

    /// Empties a cleanable folder: its contents go, the folder stays, the way Xcode
    /// expects to find DerivedData. Returns the bytes it held.
    public static func clean(_ folder: StorageFolder) -> Bool {
        guard folder.isCleanable else { return false }
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(atPath: folder.path) else { return false }
        var ok = true
        for item in items {
            do { try fm.removeItem(atPath: (folder.path as NSString).appendingPathComponent(item)) }
            catch { ok = false }
        }
        return ok
    }
}

/// The folder measurements, kept beside the settings so a week of them survives
/// relaunches.
public struct StorageLedgerFile: Sendable {
    public let url: URL

    public init(directory: URL) {
        url = directory.appendingPathComponent("storage.json")
    }

    public func load() -> [StorageFolder] {
        guard let data = try? Data(contentsOf: url),
              let folders = try? JSONDecoder().decode([StorageFolder].self, from: data) else { return [] }
        return folders
    }

    public func save(_ folders: [StorageFolder]) {
        guard let data = try? JSONEncoder().encode(folders) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
