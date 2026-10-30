import AppKit
import ApplicationServices
import SwiftUI
import MuStatsKit

/// Hosts the popover-style panel that opens from the status item.
///
/// An `NSPanel` rather than an `NSPopover`: a popover cannot be shown without
/// activating the app, cannot survive a Space change gracefully, and gives no
/// control over its own corner radius or material.
@MainActor
public final class PanelController: NSObject, NSWindowDelegate {

    public var onVisibilityChange: ((Bool) -> Void)?
    public var onRequestSettings: (() -> Void)?
    public var onRequestQuit: (() -> Void)?
    /// Opens Activity Monitor on the given tab (0 CPU … 4 Network), or as it was left.
    public var onRequestActivityMonitor: ((Int?) -> Void)?

    private let engine: MetricsEngine
    private let settings: SettingsStore
    /// Absent in the offscreen renderer. The panel's update row is drawn from it.
    private let updates: SoftwareUpdater?
    /// Internal rather than private so tests can assert on the window this
    /// controller actually owns; `NSApp.windows` can briefly hold a second panel
    /// window while another show/hide cycle fades out.
    internal private(set) var window: PanelWindow?
    private var layout: PanelLayoutState?

    /// Every `NSEvent` monitor and notification observer this controller owns, in one
    /// place. Two collections, one lifetime: they are installed together when the
    /// panel appears and torn down together on every path that hides it.
    private var monitors: [Any] = []
    private var observers: [any NSObjectProtocol] = []

    /// Where the panel was last anchored, so it can re-anchor itself when its content
    /// changes height without being told again by the status item.
    private var lastAnchor: NSRect?
    private var lastScreen: NSScreen?

    /// Bumped on every show and hide so a fade-out that is still running cannot order
    /// out a panel the user has re-opened in the meantime.
    private var presentation: UInt64 = 0
    private var isPositioning = false

    /// Pending release of the hidden panel's view tree. See `scheduleWindowRelease`.
    private var releaseTask: Task<Void, Never>?

    /// How long a hidden panel keeps its window alive before the view tree is thrown
    /// away.
    ///
    /// The panel's SwiftUI graph costs 9.6 MB of dirty, non-reclaimable heap
    /// (`footprint`, MALLOC_SMALL, this machine) and an ordered-out window keeps every
    /// byte of it for the life of the process. Rebuilding costs 27 ms, which is far too
    /// much to pay on a panel the user opens every few minutes — so the window survives
    /// bursts of use and is only released once the panel has genuinely been left alone.
    private static let windowReleaseDelay: Duration = .seconds(120)

    public init(engine: MetricsEngine, settings: SettingsStore, updates: SoftwareUpdater? = nil) {
        self.engine = engine
        self.settings = settings
        self.updates = updates
        super.init()
    }

    public private(set) var isVisible = false {
        didSet {
            guard isVisible != oldValue else { return }
            onVisibilityChange?(isVisible)
        }
    }

    /// Live count of installed event monitors and observers.
    ///
    /// Monitor leaks are silent — nothing looks wrong until the app has forty stale
    /// global monitors — so the count is exposed for verification rather than left to
    /// be reasoned about.
    public var activeEventMonitorCount: Int { monitors.count + observers.count }

    // MARK: Presentation

    public func show(anchoredTo anchor: NSRect?, on screen: NSScreen?) {
        releaseTask?.cancel()
        releaseTask = nil
        let window = existingOrNewWindow()
        lastAnchor = anchor
        lastScreen = screen ?? anchor.flatMap(Self.screen(containing:))
        presentation &+= 1

        position(window, anchoredTo: anchor, on: lastScreen)
        window.alphaValue = 0
        // Ordering front "regardless" is what lets a menu bar app show a window while
        // another app stays active; `makeKeyAndOrderFront` would activate μStats.
        window.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motionDuration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        // Deliberately no `makeKey()`. Making a panel key programmatically activates
        // μStats even when the panel is `.nonactivatingPanel` — measured, not assumed —
        // and the frontmost app loses focus the instant the user glances at their CPU
        // usage. The panel still *can* become key (`canBecomeKey` is true), so clicking
        // a control inside it hands it the keyboard without activating the app, which
        // is exactly what a non-activating panel is for.
        installDismissMonitors()
        isVisible = true
        WindowLog.log("panel shown frame=\(window.frame) key=\(window.isKeyWindow) appActive=\(NSApp.isActive) monitors=\(activeEventMonitorCount)")
    }

    public func hide() {
        // Unconditional: a monitor must never outlive the state that installed it,
        // even if this is called on a path where the panel was already hidden.
        removeDismissMonitors()
        guard let window, isVisible else { return }
        presentation &+= 1
        let generation = presentation
        isVisible = false
        // Nothing is mid-flight once the panel is gone; the next open places the
        // window afresh.
        canvasGeneration &+= 1
        heightChangesRunning = 0
        shadowLink?.invalidate()
        shadowLink = nil
        layout?.isDisclosureTransitionActive = false
        layout?.canvasHeight = nil
        layout?.focusedModule = nil
        NSAnimationContext.runAnimationGroup { context in
            context.duration = motionDuration * 0.7
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                // The panel may have been re-opened during the fade; ordering it out
                // here would hide a window the user just asked for.
                guard let self, self.presentation == generation else { return }
                window.orderOut(nil)
            }
        }
        scheduleWindowRelease()
        WindowLog.log("panel hidden monitors=\(activeEventMonitorCount)")
    }

    /// Throw away a long-hidden panel's window, and with it the SwiftUI view tree.
    ///
    /// `orderOut` alone reclaims nothing: AppKit keeps every window that has not been
    /// *closed* in the application's window list, so a panel opened once at breakfast
    /// still holds its whole view graph at midnight.
    private func scheduleWindowRelease() {
        releaseTask?.cancel()
        releaseTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.windowReleaseDelay)
            guard !Task.isCancelled, let self, !self.isVisible, let window = self.window else { return }
            self.releaseTask = nil
            self.window = nil
            self.layout = nil
            self.lastAnchor = nil
            self.lastScreen = nil
            // Dropping the delegate first: `close` notifies it, and this controller has
            // nothing useful to do with a resize on a window it is discarding.
            window.delegate = nil
            window.close()
            WindowLog.log("panel window released after \(Self.windowReleaseDelay) hidden")
            // Closing frees the view tree, but the allocator keeps the freed pages: an
            // opened panel peaks near 185 MB and the process then sat at 66 MB for the
            // rest of the day. A turn of the run loop later, once the autorelease pool
            // has let go of the last of it, the free pages go back to the system.
            try? await Task.sleep(for: .seconds(1))
            malloc_zone_pressure_relief(nil, 0)
        }
    }

    public func reanchor(to anchor: NSRect?, on screen: NSScreen?) {
        guard let window, isVisible else { return }
        lastAnchor = anchor
        lastScreen = screen ?? anchor.flatMap(Self.screen(containing:))
        position(window, anchoredTo: anchor, on: lastScreen)
    }

    private var motionDuration: TimeInterval {
        Design.Motion.respectingAccessibility(Design.Motion.present) == nil ? 0 : 0.14
    }

    private func existingOrNewWindow() -> PanelWindow {
        if let window { return window }
        let layout = PanelLayoutState()
        layout.toggleModule = { [weak self] module in
            self?.toggleModule(module)
        }
        layout.switchTab = { [weak self] tab in
            self?.switchTab(to: tab)
        }
        let root = PanelSurface(layout: layout) {
            PanelRootView(engine: engine, settings: settings, updates: updates, layout: layout)
        }
            .environment(\.panelActions, PanelActions(
                openSettings: { [weak self] in self?.onRequestSettings?() },
                quit: { [weak self] in self?.onRequestQuit?() },
                openActivityMonitor: { [weak self] tab in
                    self?.hide()
                    self?.onRequestActivityMonitor?(tab)
                },
                dismiss: { [weak self] in self?.hide() }
            ))
        // The window tracks its content's height, so collapsing a module or ejecting a
        // volume resizes the panel instead of clipping it or leaving a gap.
        let hosting = ContentSizedHostingView(rootView: root)
        hosting.onContentSizeChange = { [weak self] in self?.scheduleContentResize() }

        let window = PanelWindow(contentView: hosting)
        window.delegate = self
        // Escape is handled here as well as by the key monitor, so it still works if
        // the panel is key but the monitor is not installed.
        window.onCancel = { [weak self] in self?.hide() }
        self.layout = layout
        self.window = window
        return window
    }

    // MARK: Geometry

    /// Open or close one module. See `animateHeightChange`.
    func toggleModule(_ module: PanelModule) {
        let target = settings.settings.panel.collapsedModules(toggling: module)
        animateHeightChange { [settings] in
            settings.update { $0.panel.collapsedModules = target }
        }
    }

    /// Switch the panel's tab, moving it to the new tab's height the same way.
    private func switchTab(to tab: PanelTab) {
        animateHeightChange { [weak layout] in layout?.pickedTab = tab }
    }

    /// Make a change that moves the panel's height, animated.
    ///
    /// The window is first held at all the room below the status item, which nobody
    /// sees: everything below the surface is transparent. Then the change is made in
    /// an animation, and SwiftUI moves the content and the surface hugging it on its
    /// own render loop. Nothing is measured beforehand, so the first frame follows
    /// the click at once, and a click while one is running simply retargets it. The
    /// window is cut back to the surface when the last running change has settled.
    private func animateHeightChange(_ change: () -> Void) {
        guard let window, isVisible, let layout,
              let animation = Design.Motion.respectingAccessibility(Design.Motion.disclosure) else {
            // Reduce Motion, or no panel on screen: the content resize path places
            // the window once the change has laid out.
            change()
            return
        }
        holdCanvas(window: window, layout: layout)
        heightChangesRunning += 1
        lastHeightChange = Date()
        let generation = canvasGeneration
        withAnimation(animation, completionCriteria: .removed) {
            change()
        } completion: { [weak self] in
            guard let self, self.canvasGeneration == generation else { return }
            self.heightChangesRunning = max(self.heightChangesRunning - 1, 0)
            if self.heightChangesRunning == 0 { self.releaseCanvas() }
        }
        // A completion that never comes would leave the window held, transparent
        // and taller than the panel, for as long as the panel stays open. It has not
        // been seen to fail, but the clock ends the hold if nothing has moved for a
        // good while after the last change.
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(1.5))
            guard let self, self.canvasGeneration == generation, self.heightChangesRunning > 0,
                  Date().timeIntervalSince(self.lastHeightChange) >= 1.4 else { return }
            self.heightChangesRunning = 0
            self.releaseCanvas()
        }
    }

    /// Changes animating now. The window is held while there is any.
    private var heightChangesRunning = 0
    private var lastHeightChange = Date.distantPast
    /// Bumped whenever a hold ends, so a late completion from an earlier one cannot
    /// end the next.
    private var canvasGeneration = 0
    /// Keeps the window's shadow on the surface while the surface moves.
    private var shadowLink: CADisplayLink?

    private var isHoldingCanvas: Bool { layout?.canvasHeight != nil }

    /// Give the window all the room below the status item, without anything visible
    /// moving: the surface keeps hugging its content at the top.
    private func holdCanvas(window: NSWindow, layout: PanelLayoutState) {
        guard layout.canvasHeight == nil else { return }
        let room = targetFrame(for: NSSize(width: window.frame.width, height: .greatestFiniteMagnitude),
                               anchoredTo: lastAnchor, on: lastScreen)
        // Only the bottom edge moves. The top and the sides are where the panel is
        // now, exactly: a canvas placed afresh landed a few points higher than the
        // resting panel, which then jumped up when the hold began and back down when
        // it ended. Never shorter than now, should the room have shrunk meanwhile.
        let current = window.frame
        let bottom = min(room.minY, current.minY)
        let canvas = NSRect(x: current.minX, y: bottom, width: current.width, height: current.maxY - bottom)
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            layout.canvasHeight = canvas.height
            layout.isDisclosureTransitionActive = true
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        window.setFrame(canvas, display: false)
        CATransaction.commit()

        // The window draws its shadow from what is opaque in it, and only works that
        // out again when asked, so it is asked on every frame the surface may move.
        if shadowLink == nil, let view = window.contentView {
            let link = view.displayLink(target: self, selector: #selector(refreshShadow))
            link.add(to: .main, forMode: .common)
            shadowLink = link
        }
        WindowLog.log("canvas held \(canvas)")
    }

    @objc private func refreshShadow() {
        window?.invalidateShadow()
    }

    /// Cut the window back to the surface, in one unanimated pass, so the last frame
    /// of the animation and the first still frame are the same picture.
    private func releaseCanvas() {
        canvasGeneration &+= 1
        heightChangesRunning = 0
        shadowLink?.invalidate()
        shadowLink = nil
        guard let window, let layout, layout.canvasHeight != nil else { return }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        withTransaction(transaction) {
            layout.canvasHeight = nil
            layout.isDisclosureTransitionActive = false
        }
        position(window, anchoredTo: lastAnchor, on: lastScreen)
        window.displayIfNeeded()
        window.invalidateShadow()
        CATransaction.commit()
        WindowLog.log("canvas released win=\(window.frame)")
    }

    /// Anchor under the status item, nudged so the panel never hangs off the screen,
    /// slides under the menu bar, or grows past the bottom of the display.
    private func position(_ window: NSWindow, anchoredTo anchor: NSRect?, on screen: NSScreen?) {
        guard !isPositioning else { return }
        isPositioning = true
        defer { isPositioning = false }

        window.layoutIfNeeded()
        let fitting = window.contentView?.fittingSize
            ?? NSSize(width: PanelSettings.width, height: 400)
        // A layout measured mid-transaction can report an empty intrinsic size;
        // applied, it once teleported the panel to a zero-sized frame.
        guard fitting.width > 0, fitting.height > 0 else { return }

        let frame = targetFrame(for: fitting, anchoredTo: anchor, on: screen)
        guard frame != window.frame else { return }
        WindowLog.log("position \(window.frame) -> \(frame) fitting=\(fitting)")
        window.setFrame(frame, display: true)
    }

    private func targetFrame(for fitting: NSSize, anchoredTo anchor: NSRect?,
                             on screen: NSScreen?) -> NSRect {
        // The status item's own screen is the right one even when it is not the
        // primary: `visibleFrame` is in global coordinates, so a display whose menu
        // bar sits below or beside the primary's still resolves correctly.
        let targetScreen = screen
            ?? anchor.flatMap(Self.screen(containing:))
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let visible = targetScreen?.visibleFrame else { return window?.frame ?? .zero }

        let margin = Design.Space.m
        let gap = Design.Space.s

        // Height is capped to the room actually below the status item. Without this a
        // panel with every module enabled runs off the bottom of a short display, and
        // the modules nearest the bottom become unreachable.
        let available = anchor.map { ($0.minY - gap) - (visible.minY + margin) }
            ?? (visible.height - margin * 2)
        // Whole points. A window cannot hold a half-point height, so a 568.5pt fit set
        // a 569pt frame that never compared equal to the frame asked for, and every
        // placement after it was a change that had to be applied again.
        let size = NSSize(width: fitting.width,
                          height: ceil(min(fitting.height, max(available, 160))))

        var x: CGFloat
        var y: CGFloat
        if let anchor {
            x = anchor.midX - size.width / 2
            y = anchor.minY - size.height - gap
        } else {
            // The status item is hidden — pushed off a crowded menu bar or behind the
            // notch. Fall back to the top trailing corner of its display, which is
            // where the item would have been.
            x = visible.maxX - size.width - margin
            y = visible.maxY - size.height - gap
        }

        // Keep fully on screen with a consistent margin, matching how macOS clamps
        // its own menu bar popovers.
        x = min(max(x, visible.minX + margin), max(visible.maxX - size.width - margin, visible.minX + margin))
        y = min(max(y, visible.minY + margin), max(visible.maxY - size.height - margin, visible.minY + margin))

        // One frame mutation, not two.
        //
        // This used to be `setContentSize` followed by `setFrameOrigin`. `setContentSize`
        // keeps the window's bottom-left origin and moves its top edge, which for a panel
        // pinned under the status item is the wrong edge entirely: the window grew upwards
        // into the menu bar and the origin call then dragged it back down. Two mutations
        // also meant two `windowDidResize` notifications, and that delegate re-enters this
        // method — `isPositioning` only guards the synchronous case, so the asynchronous
        // one came back a beat later and resized again. That second, late resize is what
        // read as a jitter.
        //
        // Setting the whole frame at once makes an unchanged placement a genuine no-op,
        // which is what stops the re-entrant pass from moving anything.
        return NSRect(x: x.rounded(), y: y.rounded(),
                      width: size.width, height: size.height)
    }

    private static func screen(containing rect: NSRect) -> NSScreen? {
        NSScreen.screens.first { $0.frame.intersects(rect) }
    }

    private static let escapeKeyCode: UInt16 = 53

    /// SwiftUI can invalidate its size several times in one layout pass, so the
    /// window is re-measured once on the next turn rather than on every invalidation.
    private func scheduleContentResize() {
        guard !isHoldingCanvas else { return }
        guard !hasPendingResize else { return }
        hasPendingResize = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.hasPendingResize = false
            // A resize queued on the turn before a click would otherwise fire mid-
            // transition and snap the window to the destination unanimated.
            guard let window = self.window, self.isVisible,
                  !self.isHoldingCanvas else { return }
            self.position(window, anchoredTo: self.lastAnchor, on: self.lastScreen)
        }
    }

    private var hasPendingResize = false

    /// SwiftUI grows the window downwards from its bottom-left corner; re-running the
    /// placement re-pins it under the status item and re-applies the height cap.
    /// While the panel changes height the window is held on purpose and is placed
    /// when the change ends.
    public func windowDidResize(_ notification: Notification) {
        guard let window, isVisible, !isPositioning, !isHoldingCanvas else { return }
        position(window, anchoredTo: lastAnchor, on: lastScreen)
    }

    /// Covers the dismissal the mouse monitor cannot see: ⌘-tabbing to another app.
    public func windowDidResignKey(_ notification: Notification) {
        guard isVisible else { return }
        WindowLog.log("panel resigned key; dismissing")
        hide()
    }

    // MARK: Dismissal

    private func installDismissMonitors() {
        removeDismissMonitors()

        // The local monitor covers the case where the panel has taken the keyboard; the
        // global one covers the far more common case where it has not, and only exists
        // when the app is already trusted for accessibility — this never prompts for a
        // permission.
        if let escape = NSEvent.addLocalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
            guard let self else { return event }
            switch event.keyCode {
            case Self.escapeKeyCode:
                Task { @MainActor in self.hide() }
                return nil
            case 126: // Up Arrow
                Task { @MainActor in self.moveFocus(delta: -1) }
                return nil
            case 125: // Down Arrow
                Task { @MainActor in self.moveFocus(delta: 1) }
                return nil
            case 36, 49: // Return or Space
                Task { @MainActor in self.toggleFocusedModule() }
                return nil
            default:
                // 1 to 9 jump to that module and open it.
                guard event.modifierFlags.intersection(.deviceIndependentFlagsMask).subtracting(.numericPad).isEmpty,
                      let digit = event.charactersIgnoringModifiers.flatMap(Int.init),
                      (1...9).contains(digit) else { return event }
                Task { @MainActor in self.jump(to: digit - 1) }
                return nil
            }
        }) {
            monitors.append(escape)
        }
        if AXIsProcessTrusted(),
           let escape = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown], handler: { [weak self] event in
               guard event.keyCode == Self.escapeKeyCode else { return }
               Task { @MainActor in self?.hide() }
           }) {
            monitors.append(escape)
        }

        // Global monitors see only events destined for *other* apps, so a click inside
        // the panel never reaches this and cannot dismiss it.
        if let outside = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown],
            handler: { [weak self] _ in
                Task { @MainActor in self?.hide() }
            }) {
            monitors.append(outside)
        }

        observers.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    WindowLog.log("active space changed; dismissing panel")
                    self?.hide()
                }
        })

        WindowLog.log("panel monitors installed count=\(activeEventMonitorCount)")
    }

    private func moveFocus(delta: Int) {
        let visible = settings.settings.panel.visibleModules
        guard !visible.isEmpty else { return }
        guard let current = layout?.focusedModule, let index = visible.firstIndex(of: current) else {
            layout?.focusedModule = delta > 0 ? visible.first : visible.last
            return
        }
        let nextIndex = min(max(index + delta, 0), visible.count - 1)
        layout?.focusedModule = visible[nextIndex]
    }

    private func jump(to index: Int) {
        let visible = settings.settings.panel.visibleModules
        guard visible.indices.contains(index) else { return }
        let module = visible[index]
        layout?.focusedModule = module
        if settings.settings.panel.collapsedModules.contains(module) {
            toggleModule(module)
        }
    }

    private func toggleFocusedModule() {
        guard let focused = layout?.focusedModule else { return }
        toggleModule(focused)
    }

    private func removeDismissMonitors() {
        for monitor in monitors { NSEvent.removeMonitor(monitor) }
        monitors.removeAll()
        for observer in observers {
            NSWorkspace.shared.notificationCenter.removeObserver(observer)
        }
        observers.removeAll()
    }
}

/// Borderless, non-activating, transparent panel; its content draws the glass.
final class PanelWindow: NSPanel {

    var onCancel: (() -> Void)?

    init(contentView: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: 340, height: 400),
                   styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
                   backing: .buffered,
                   defer: false)

        isFloatingPanel = true
        level = .statusBar
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        hidesOnDeactivate = false
        animationBehavior = .none
        isRestorable = false
        // `close()` is how the controller reclaims the view tree, and the default here
        // is to have the window release itself when that happens — which, on a window
        // ARC already owns through `PanelController.window`, is an over-release.
        isReleasedWhenClosed = false
        // Follow the user across Spaces and appear over full-screen apps, the way
        // the system's own menu bar extras do.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        isMovableByWindowBackground = false
        title = "μStats Panel"

        // The glass is drawn by the content, so it can change height inside a window
        // that holds still. See `PanelSurface`.
        self.contentView = contentView
    }

    /// Borderless windows are not key by default, which would break text fields
    /// and keyboard navigation inside the panel. Becoming key does not activate the
    /// app: that is exactly what `.nonactivatingPanel` buys.
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    /// The responder-chain half of Escape-to-dismiss, for when the key window is the
    /// panel but focus sits on a control that swallows the key event.
    override func cancelOperation(_ sender: Any?) { onCancel?() }
}

// MARK: - Actions plumbed through the environment

/// Not `Sendable`: every action targets the main actor by construction, and the
/// environment only ever carries it between main-actor views.
public struct PanelActions {
    public var openSettings: @MainActor () -> Void
    public var quit: @MainActor () -> Void
    public var openActivityMonitor: @MainActor (Int?) -> Void
    public var dismiss: @MainActor () -> Void

    public init(openSettings: @escaping @MainActor () -> Void = {},
                quit: @escaping @MainActor () -> Void = {},
                openActivityMonitor: @escaping @MainActor (Int?) -> Void = { _ in },
                dismiss: @escaping @MainActor () -> Void = {}) {
        self.openSettings = openSettings
        self.quit = quit
        self.openActivityMonitor = openActivityMonitor
        self.dismiss = dismiss
    }
}

private struct PanelActionsKey: EnvironmentKey {
    static let defaultValue = PanelActions()
}

extension EnvironmentValues {
    public var panelActions: PanelActions {
        get { self[PanelActionsKey.self] }
        set { self[PanelActionsKey.self] = newValue }
    }
}
