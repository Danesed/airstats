import SwiftUI
import AppKit
import MuStatsKit

/// "Keeping the Mac awake": the apps and tools holding off sleep, with a way to
/// quit them. Read when the section is on screen and every few seconds while it
/// stays there; nothing runs while the panel is closed.
struct PanelSleepBlockers: View {
    @State private var blockers: [SleepBlocker] = []
    @State private var loaded = false

    private static let refresh: Duration = .seconds(5)

    var body: some View {
        VStack(alignment: .leading, spacing: Design.Space.xxs + 1) {
            PanelSectionLabel("Keeping the Mac awake")
            if loaded && blockers.isEmpty {
                Text("Nothing. The Mac can sleep when it is idle.")
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
            }
            ForEach(blockers) { blocker in
                row(blocker)
            }
        }
        .padding(.top, Design.Space.xs)
        .task {
            while !Task.isCancelled {
                let found = await Task.detached(priority: .utility) { SleepBlockers.current() }.value
                blockers = found
                loaded = true
                try? await Task.sleep(for: Self.refresh)
            }
        }
    }

    private func row(_ blocker: SleepBlocker) -> some View {
        let app = NSRunningApplication(processIdentifier: blocker.pid)
        let name = app?.localizedName ?? blocker.processName
        let what = blocker.hold == .display ? String(localized: "Keeps the display on")
                                            : String(localized: "Keeps the Mac awake")
        return HStack(spacing: Design.Space.s) {
            if let icon = app?.icon {
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: Design.Space.l, height: Design.Space.l)
            } else {
                Image(systemName: "gearshape.fill")
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .frame(width: Design.Space.l, height: Design.Space.l)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(name)
                    .font(Design.Text.body)
                    .foregroundStyle(Design.Palette.primaryText)
                    .lineLimit(1)
                Text(blocker.reason.isEmpty ? what : "\(what) · \(blocker.reason)")
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.secondaryText)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: Design.Space.s)
        }
        .padding(.vertical, Design.Space.xxs)
        .accessibilityElement(children: .combine)
        .contextMenu {
            Button(role: .destructive) {
                if let app { app.terminate() } else { kill(blocker.pid, SIGTERM) }
            } label: {
                Label("Quit \(name)", systemImage: "xmark.circle")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("\(blocker.pid)", forType: .string)
            } label: {
                Label("Copy PID (\(blocker.pid))", systemImage: "doc.on.doc")
            }
        }
    }
}
