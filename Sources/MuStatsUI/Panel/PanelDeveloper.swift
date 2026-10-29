import SwiftUI
import AppKit
import MuStatsKit

/// A cancellation flag a detached task can poll, set from the task that awaits it.
private final class CancelFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }
}

/// "Listening": the development servers, databases and tools waiting for
/// connections, and the containers Docker is running. Read when the network module
/// is open and every ten seconds while it stays open; nothing runs otherwise.
struct PanelListeningPorts: View {
    @State private var ports: [ListeningPort] = []
    @State private var containers: [DockerContainer] = []
    @State private var loaded = false

    private static let refresh: Duration = .seconds(10)
    private static let shown = 8

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs + 1) {
            // Nothing at all until the first read is in: a heading over an empty
            // space reads as a list that failed rather than one still coming.
            if loaded { PanelSectionLabel("Listening") }
            if loaded && ports.isEmpty {
                Text("Nothing of yours is listening for connections.")
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
            }
            ForEach(ports.prefix(Self.shown)) { port in
                portRow(port)
            }
            if ports.count > Self.shown {
                Text("and \(ports.count - Self.shown) more")
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
            if !containers.isEmpty {
                PanelSectionLabel("Docker")
                    .padding(.top, Design.Space.xs)
                ForEach(containers) { container in
                    containerRow(container)
                }
            }
        }
        .padding(.top, Design.Space.xs)
        .task {
            while !Task.isCancelled {
                let (found, running) = await Task.detached(priority: .utility) {
                    (ListeningPorts.current(), DockerAPI.socketPath == nil ? [] : (DockerAPI.containers() ?? []))
                }.value
                ports = found
                containers = running
                loaded = true
                try? await Task.sleep(for: Self.refresh)
            }
        }
    }

    /// The Docker container behind a published port, when Docker is the listener.
    private func container(publishing port: Int) -> DockerContainer? {
        containers.first { $0.ports.contains { $0.publicPort == port } }
    }

    private func portRow(_ port: ListeningPort) -> some View {
        let app = NSRunningApplication(processIdentifier: port.pid)
        let owner = container(publishing: port.port).map { "\($0.name) (Docker)" }
            ?? app?.localizedName ?? port.processName
        return HStack(spacing: Design.Space.s) {
            Text(verbatim: "\(port.port)")
                .font(Design.Text.value.monospacedDigit())
                .foregroundStyle(Design.Palette.primaryText)
                .frame(width: 44, alignment: .leading)
            Text(owner)
                .font(Design.Text.body)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: Design.Space.s)
            if port.isExposed {
                // Bound to every interface: anyone on this network can reach it.
                Text("open to the network")
                    .font(Design.Text.caption)
                    .foregroundStyle(Color.orange)
                    .lineLimit(1)
            }
        }
        .frame(height: 18)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button {
                if let url = URL(string: "http://localhost:\(port.port)") { NSWorkspace.shared.open(url) }
            } label: {
                Label("Open localhost:\(port.port) in Browser", systemImage: "safari")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("localhost:\(port.port)", forType: .string)
            } label: {
                Label("Copy localhost:\(port.port)", systemImage: "doc.on.doc")
            }
            Divider()
            Button(role: .destructive) {
                if let app { app.terminate() } else { kill(port.pid, SIGTERM) }
            } label: {
                Label("Quit \(app?.localizedName ?? port.processName)", systemImage: "xmark.circle")
            }
        }
    }

    private func containerRow(_ container: DockerContainer) -> some View {
        let published = container.ports.compactMap(\.publicPort)
        let ports = Array(Set(published)).sorted().map { ":\($0)" }.joined(separator: " ")
        return HStack(spacing: Design.Space.s) {
            Image(systemName: "shippingbox")
                .font(Design.Text.caption)
                .foregroundStyle(Design.Palette.secondaryText)
                .frame(width: Design.Space.l)
            VStack(alignment: .leading, spacing: 0) {
                Text(container.name)
                    .font(Design.Text.body)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                Text(container.image)
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: Design.Space.s)
            if !ports.isEmpty {
                Text(ports)
                    .font(Design.Text.caption.monospacedDigit())
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// "Where the space went": how much more the disk holds than yesterday, and the
/// folders known to grow, with what each added. The change comes from the month of
/// history already kept; the folders are measured when the module is open and the
/// last measurement is six hours old, and the measuring stops if it closes.
struct PanelStorageInsights: View {
    let engine: MetricsEngine
    let directory: URL

    @Environment(\.metricFormatter) private var formatter
    @State private var folders: [StorageFolder] = []
    @State private var measuring = false
    @State private var docker: DockerDiskUsage?
    @State private var confirming: String?
    @State private var cleaning: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs + 1) {
            if hasContent { PanelSectionLabel("Where the space went") }
            if let change = usedChange {
                Text(change)
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
            }
            ForEach(listed) { folder in
                folderRow(folder)
            }
            if let docker, docker.total >= StorageScan.worthListing {
                row(label: "Docker images, volumes and cache", bytes: docker.total, change: nil, folder: nil)
            }
            if measuring {
                Text(folders.isEmpty ? "Measuring folders…" : "Measuring again…")
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.tertiaryText)
            }
        }
        .padding(.top, Design.Space.xs)
        .task { await refresh() }
    }

    private var ledger: StorageLedgerFile { StorageLedgerFile(directory: directory) }

    private var hasContent: Bool {
        usedChange != nil || !listed.isEmpty || measuring
            || (docker.map { $0.total >= StorageScan.worthListing } ?? false)
    }

    private var listed: [StorageFolder] {
        folders.filter { ($0.bytes ?? 0) >= StorageScan.worthListing }
            .sorted { ($0.bytes ?? 0) > ($1.bytes ?? 0) }
    }

    /// "Used 23 GB more than yesterday · 41 GB more than a week ago", from the hourly
    /// month tier. Nothing when the change is under half a gigabyte either way.
    private var usedChange: String? {
        guard let root = engine.disk.value?.rootVolume, root.totalBytes > 0,
              let now = engine.monthHistory.average(.diskUsed, at: Date()) else { return nil }
        func delta(_ ago: TimeInterval) -> Int64? {
            engine.monthHistory.average(.diskUsed, at: Date().addingTimeInterval(-ago)).map {
                Int64((now - $0) * Double(root.totalBytes))
            }
        }
        func say(_ bytes: Int64, _ when: String) -> String? {
            guard abs(bytes) >= 500_000_000 else { return nil }
            let amount = formatter.storage(UInt64(abs(bytes)))
            return bytes > 0 ? "\(amount) more used than \(when)" : "\(amount) freed since \(when)"
        }
        let parts = [delta(86_400).flatMap { say($0, "yesterday") },
                     delta(7 * 86_400).flatMap { say($0, "a week ago") }].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func refresh() async {
        let file = ledger
        folders = await Task.detached(priority: .utility) { file.load() }.value
        if DockerAPI.socketPath != nil {
            docker = await Task.detached(priority: .utility) { DockerAPI.diskUsage() }.value
        }
        let newest = folders.compactMap { $0.samples.last?.date }.max()
        guard newest.map({ Date().timeIntervalSince($0) >= StorageScan.staleAfter }) ?? true else { return }
        measuring = true
        defer { measuring = false }
        let previous = folders
        let flag = CancelFlag()
        let scanned = await withTaskCancellationHandler {
            await Task.detached(priority: .background) {
                StorageScan.scan(previous: previous, isCancelled: { flag.isCancelled })
            }.value
        } onCancel: {
            flag.cancel()
        }
        guard let scanned, !Task.isCancelled else { return }
        folders = scanned
        await Task.detached(priority: .utility) { file.save(scanned) }.value
    }

    private func folderRow(_ folder: StorageFolder) -> some View {
        row(label: folder.label, bytes: folder.bytes ?? 0, change: folder.change, folder: folder)
    }

    private func row(label: String, bytes: UInt64, change: (bytes: Int64, since: Date)?,
                     folder: StorageFolder?) -> some View {
        HStack(spacing: Design.Space.s) {
            VStack(alignment: .leading, spacing: 0) {
                Text(label)
                    .font(Design.Text.body)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                if let change, abs(change.bytes) >= Int64(StorageScan.worthListing) {
                    Text("\(change.bytes > 0 ? "+" : "−")\(formatter.storage(UInt64(abs(change.bytes)))) since \(Self.day(change.since))")
                        .font(Design.Text.caption)
                        .foregroundStyle(change.bytes >= 5_000_000_000 ? Color.orange : Design.Palette.secondaryText)
                }
            }
            Spacer(minLength: Design.Space.s)
            if let folder, folder.isCleanable {
                cleanButton(folder, bytes: bytes)
            }
            Text(formatter.storage(bytes))
                .font(Design.Text.value)
                .foregroundStyle(Design.Palette.primaryText)
                .lineLimit(1)
        }
        .padding(.vertical, Design.Space.xxs)
        .contentShape(Rectangle())
        .contextMenu {
            if let folder {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: folder.path)])
                } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
            }
        }
    }

    /// Two presses: the first turns the button into the question, the second empties
    /// the folder. Not while Xcode is open, which would be building into it.
    @ViewBuilder
    private func cleanButton(_ folder: StorageFolder, bytes: UInt64) -> some View {
        let xcodeOpen = !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dt.Xcode").isEmpty
        if cleaning == folder.id {
            ProgressView().controlSize(.small)
        } else {
            Button(confirming == folder.id ? "Delete \(formatter.storage(bytes))?" : "Clean") {
                if confirming == folder.id {
                    confirming = nil
                    clean(folder)
                } else {
                    confirming = folder.id
                    Task {
                        try? await Task.sleep(for: .seconds(4))
                        if confirming == folder.id { confirming = nil }
                    }
                }
            }
            .controlSize(.small)
            .tint(confirming == folder.id ? .red : nil)
            .disabled(xcodeOpen)
            .help(xcodeOpen ? "Quit Xcode first: it builds into this folder." : "Xcode rebuilds it the next time it needs it.")
        }
    }

    private func clean(_ folder: StorageFolder) {
        cleaning = folder.id
        let file = ledger
        let current = folders
        Task {
            let updated = await Task.detached(priority: .utility) { () -> [StorageFolder] in
                _ = StorageScan.clean(folder)
                let left = StorageScan.measure(URL(fileURLWithPath: folder.path), isCancelled: { false }) ?? 0
                let result = current.map { entry -> StorageFolder in
                    guard entry.id == folder.id else { return entry }
                    var cleaned = entry
                    cleaned.samples = StorageScan.fold(entry.samples, .init(date: Date(), bytes: left))
                    return cleaned
                }
                file.save(result)
                return result
            }.value
            folders = updated
            cleaning = nil
        }
    }

    private static func day(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInYesterday(date) { return "yesterday" }
        if calendar.isDateInToday(date) { return HistoryAxis.clock(date) }
        return date.formatted(.dateTime.weekday(.wide))
    }
}
