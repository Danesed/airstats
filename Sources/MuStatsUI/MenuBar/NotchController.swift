import AppKit
import SwiftUI
import MuStatsKit

/// Notch mode: on a MacBook with a notch, resting the pointer on the notch opens the
/// readings under it.
///
/// A crowded menu bar hides status items behind the notch, readings included. The
/// notch itself is the one stretch of the bar nothing else can use, so it is where
/// the readings go when the bar has no room for them.
///
/// Cost while closed: one transparent window per notched screen, the size of the
/// notch, with a tracking area. The readings view exists only while it is open.
@MainActor
public final class NotchController {

    private let engine: MetricsEngine
    private let settings: SettingsStore
    /// What a click on the open readings does: the full panel.
    public var onOpenPanel: (() -> Void)?

    private var windows: [NotchWindow] = []
    private var observation: Task<Void, Never>?
    private var screenObserver: NSObjectProtocol?

    public init(engine: MetricsEngine, settings: SettingsStore) {
        self.engine = engine
        self.settings = settings
    }

    public func start() {
        guard observation == nil else { return }
        sync()
        observation = Task { @MainActor [weak self] in
            guard let settings = self?.settings else { return }
            for await _ in ObservedChanges(tracking: { _ = settings.revision }) {
                self?.sync()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    public func stop() {
        observation?.cancel()
        observation = nil
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
        screenObserver = nil
        tearDown()
    }

    private var isWanted: Bool {
        settings.settings.menuBar.showsNotchReadings && settings.settings.menuBar.isVisible
    }

    private func sync() {
        if isWanted {
            if windows.isEmpty { rebuild() }
        } else {
            tearDown()
        }
    }

    private func rebuild() {
        tearDown()
        guard isWanted else { return }
        for screen in NSScreen.screens {
            guard let notch = Self.notchRect(on: screen) else { continue }
            let window = NotchWindow(notch: notch, engine: engine, settings: settings)
            window.onClick = { [weak self] in self?.onOpenPanel?() }
            window.orderFrontRegardless()
            windows.append(window)
        }
    }

    private func tearDown() {
        for window in windows { window.close() }
        windows.removeAll()
    }

    /// The notch in screen coordinates: the gap between the two stretches of menu bar
    /// either side of the camera, as tall as the safe-area inset at the top.
    static func notchRect(on screen: NSScreen) -> NSRect? {
        guard screen.safeAreaInsets.top > 0,
              let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea,
              right.minX > left.maxX else { return nil }
        let height = screen.safeAreaInsets.top
        return NSRect(x: left.maxX, y: screen.frame.maxY - height,
                      width: right.minX - left.maxX, height: height)
    }
}

/// One notch's window: the notch's own size while closed, grown downward into a
/// black island that reads as the notch itself opening while the pointer is on it.
private final class NotchWindow: NSPanel {
    var onClick: (() -> Void)?

    private let notch: NSRect
    private let engine: MetricsEngine
    private let settings: SettingsStore
    private var hosting: NSHostingView<NotchIslandView>?
    private var pending: DispatchWorkItem?

    /// The open island: wider than the notch, and tall enough for one row of readings.
    private static let openSize = NSSize(width: 360, height: 70)

    init(notch: NSRect, engine: MetricsEngine, settings: SettingsStore) {
        self.notch = notch
        self.engine = engine
        self.settings = settings
        super.init(contentRect: notch, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        level = .statusBar
        // Set explicitly: left to the default, a transparent window lets the pointer
        // fall through and the tracking area never hears it arrive.
        ignoresMouseEvents = false
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        isReleasedWhenClosed = false
        let tracker = NotchTrackingView(frame: NSRect(origin: .zero, size: notch.size))
        tracker.onEnter = { [weak self] in self?.schedule(open: true) }
        tracker.onExit = { [weak self] in self?.schedule(open: false) }
        tracker.onClick = { [weak self] in self?.onClick?() }
        tracker.autoresizingMask = [.width, .height]
        contentView = tracker
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// A short wait each way: the pointer crossing the notch on its way somewhere
    /// else should not flash the readings open, and leaving the island for a moment
    /// should not snap it shut.
    private func schedule(open: Bool) {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in open ? self?.open() : self?.shut() }
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (open ? 0.18 : 0.35), execute: work)
    }

    private func open() {
        guard hosting == nil, let tracker = contentView else { return }
        let size = NSSize(width: max(Self.openSize.width, notch.width + 80),
                          height: notch.height + Self.openSize.height)
        let frame = NSRect(x: notch.midX - size.width / 2, y: notch.maxY - size.height,
                           width: size.width, height: size.height)
        let view = NSHostingView(rootView: NotchIslandView(engine: engine, settings: settings,
                                                           notchHeight: notch.height))
        view.frame = NSRect(origin: .zero, size: size)
        view.autoresizingMask = [.width, .height]
        tracker.addSubview(view)
        hosting = view
        setFrame(frame, display: true)
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            view.animator().alphaValue = 1
        }
    }

    private func shut() {
        guard let view = hosting else { return }
        hosting = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.15
            view.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                view.removeFromSuperview()
                guard let self, self.hosting == nil else { return }
                self.setFrame(self.notch, display: true)
            }
        })
    }
}

/// Hears the pointer arrive and leave, and a click, over whatever the window shows.
private final class NotchTrackingView: NSView {
    var onEnter: (() -> Void)?
    var onExit: (() -> Void)?
    var onClick: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        self.area = area
    }

    override func mouseEntered(with event: NSEvent) { onEnter?() }
    override func mouseExited(with event: NSEvent) { onExit?() }
    override func mouseUp(with event: NSEvent) { onClick?() }
    override func hitTest(_ point: NSPoint) -> NSView? {
        // Clicks land here, not on the readings, so the whole island opens the panel.
        frame.contains(convert(point, from: superview)) ? self : nil
    }
}

/// The open notch: a black island under the camera with the readings in one row.
struct NotchIslandView: View {
    let engine: MetricsEngine
    let settings: SettingsStore
    let notchHeight: CGFloat

    var body: some View {
        let formatter = MetricFormatter(settings: settings.settings.general)
        let readings = Self.readings(engine.snapshot, formatter)
        VStack(spacing: 0) {
            Color.clear.frame(height: notchHeight)
            HStack(spacing: 18) {
                ForEach(readings, id: \.label) { reading in
                    VStack(spacing: 1) {
                        Text(localizing: reading.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.55))
                        UnitText.text(reading.value, size: 14, weight: .semibold)
                            .foregroundStyle(reading.alert ? Color.orange : .white)
                            .lineLimit(1)
                    }
                }
            }
            .padding(.horizontal, 18)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(
            UnevenRoundedRectangle(bottomLeadingRadius: 20, bottomTrailingRadius: 20, style: .continuous)
                .fill(Color.black)
        )
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    struct Reading {
        var label: String
        var value: String
        var alert = false
    }

    static func readings(_ s: SystemSnapshot, _ f: MetricFormatter) -> [Reading] {
        var result: [Reading] = []
        if let cpu = s.cpu.value {
            result.append(Reading(label: "CPU", value: f.percent(cpu.total.busy), alert: cpu.total.busy >= 0.9))
        }
        if let memory = s.memory.value {
            result.append(Reading(label: "MEM", value: f.percent(memory.usedFraction),
                                  alert: memory.pressureFraction >= 0.7))
        }
        if let celsius = s.thermal.value?.cpuCelsius {
            result.append(Reading(label: "TEMP", value: f.temperature(celsius), alert: celsius >= 85))
        }
        if let network = s.network.value {
            result.append(Reading(label: "↓ NET", value: f.networkRate(network.downloadBytesPerSecond, compact: true)))
        }
        if let power = s.power.value, power.hasBattery, let percent = power.percentage {
            result.append(Reading(label: power.isCharging ? "CHARGING" : "BATTERY",
                                  value: f.percentValue(percent), alert: !power.isPluggedIn && percent <= 15))
        }
        return result
    }
}
