import SwiftUI
import AppKit
import Observation
import MuStatsKit

/// Ephemeral presentation state shared by the panel's SwiftUI tree and its AppKit
/// controller. Settings remain the durable truth; the override exists only long enough
/// to measure and animate one disclosure as a coordinated transaction.
@MainActor
@Observable
final class PanelLayoutState {
    var collapsedModulesOverride: Set<PanelModule>?
    /// The collapsed set a disclosure started from, held until it has finished.
    var disclosureOrigin: Set<PanelModule>?
    var isDisclosureTransitionActive = false
    var focusedModule: PanelModule?
    @ObservationIgnored var toggleModule: ((PanelModule) -> Void)?
}

/// Root of the click-down panel.
///
/// A stack of modules in the user's order, each carrying its own headline value, over
/// a footer. The panel sizes to its content and has no chrome of its own; it scrolls
/// only in the one case where it would otherwise run off the screen.
public struct PanelRootView: View {

    private let engine: MetricsEngine
    private let settings: SettingsStore
    /// Absent in the offscreen renderer, which has no Sparkle to ask.
    private let updates: SoftwareUpdater?
    /// Absent in renderers and previews, where disclosure writes settings directly.
    private let layout: PanelLayoutState?

    public init(engine: MetricsEngine, settings: SettingsStore, updates: SoftwareUpdater? = nil) {
        self.engine = engine
        self.settings = settings
        self.updates = updates
        self.layout = nil
    }

    init(engine: MetricsEngine, settings: SettingsStore, updates: SoftwareUpdater?,
         layout: PanelLayoutState) {
        self.engine = engine
        self.settings = settings
        self.updates = updates
        self.layout = layout
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let pending = updates?.pending {
                PanelUpdateRow(update: pending) { [updates] in
                    // Sparkle's window is a window, and the panel closes when it loses
                    // key, so it would take the update with it on the way out.
                    actions.dismiss()
                    updates?.installPending()
                }
                PanelSeparator()
            }
            PanelHeaderView(tab: tab, showsTabs: settings.settings.panel.showsToday,
                            isStale: engine.isStale)
            if shownTab == .now {
                PanelInsightRow(insight: insight, open: open)
                    .padding(.horizontal, Design.Space.s)
                    .padding(.top, Design.Space.s)
            }
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 0) {
                    if shownTab == .today {
                        PanelTodayCard(engine: engine, settings: settings) { module in
                            pickedTab = .now
                            open(module)
                        }
                        .panelCard()
                        .padding(.top, Design.Space.s)
                    } else {
                        let captionColumnWidth = captionColumnWidth
                        let nameColumnWidth = nameColumnWidth
                        ForEach(PanelGroup.arrange(modules), id: \.group) { entry in
                            PanelGroupLabel(entry.group.title)
                            VStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(entry.modules.enumerated()), id: \.element) { index, module in
                                    if index > 0 { PanelSeparator() }
                                    moduleView(module, captionColumnWidth: captionColumnWidth,
                                               nameColumnWidth: nameColumnWidth)
                                }
                            }
                            .padding(.vertical, Design.Space.xxs)
                            .panelCard()
                        }
                    }
                }
                .padding(.bottom, Design.Space.s)
            }
            .scrollBounceBehavior(.basedOnSize)
            // No indicator, ever.
            //
            // The window is sized to this list, so in the ordinary case there is
            // nothing to scroll and nothing for an indicator to report. What it does
            // instead is flicker: every change in content height leaves one layout pass
            // in which the list is taller than the window that has not yet grown to
            // hold it, and the scroll view spends that pass showing a scroller. Under
            // `Show scroll bars: Always` that scroller is a legacy one, so it also
            // takes real width and reflows the text beneath it on the way in and out.
            // `.never` rather than `.automatic`, because `.hidden` still defers to that
            // setting. The list stays scrollable by trackpad and wheel for the rare
            // case that it reaches the ceiling below.
            .scrollIndicators(.never)
            .defaultScrollAnchor(.top)
        }
        // The list takes whatever height the window has, and the rows sit at its top.
        //
        // The window's frame and this hierarchy's height animate as two systems, and
        // for the frames where they disagree something has to give. It used to be the
        // list: sized to its content and capped by a `frame(maxHeight:)`, it was
        // centred in the room the window offered, so every row slid down by half the
        // difference while the window led and back up as the content caught up. The
        // header being clicked moved under the pointer. Letting the scroll view fill
        // the window instead keeps every row where it is; the disagreement lands on
        // the footer, which rides the window's bottom edge, and on a few points of
        // list clipped behind it while the content leads.
        //
        // Sizing: the window is measured from this hierarchy's ideal height, which for
        // a scroll view is its content, so below the screen's ceiling nothing scrolls.
        // Past it the controller caps the window and the list scrolls under a footer
        // that stays on screen.
        .frame(maxHeight: .infinity, alignment: .top)
        .frame(width: PanelSettings.width)
        .environment(\.metricFormatter, MetricFormatter(settings: settings.settings.general))
    }

    @Environment(\.panelActions) private var actions
    @State private var pickedTab: PanelTab?
    @Environment(\.panelInitialTab) private var initialTab

    private var tab: Binding<PanelTab> {
        Binding(get: { pickedTab ?? initialTab }, set: { pickedTab = $0 })
    }

    /// Today with the switch off is Now, whatever was picked before it went off.
    private var shownTab: PanelTab {
        settings.settings.panel.showsToday ? (pickedTab ?? initialTab) : .now
    }

    private func moduleView(_ module: PanelModule, captionColumnWidth: CGFloat,
                            nameColumnWidth: CGFloat) -> some View {
        PanelModuleView(module: module, engine: engine, settings: settings,
                        layout: layout, captionColumnWidth: captionColumnWidth,
                        nameColumnWidth: nameColumnWidth)
            .draggable(module.rawValue) {
                Label(module.label, systemImage: module.symbolName)
                    .font(Design.Text.rowTitle)
                    .padding(Design.Space.s)
            }
            .dropDestination(for: String.self) { items, _ in
                guard let raw = items.first, let dragged = PanelModule(rawValue: raw),
                      dragged != module else { return false }
                withAnimation(Design.Motion.respectingAccessibility(Design.Motion.disclosure)) {
                    settings.update { s in
                        s.panel.moduleOrder = s.panel.moduleOrder(moving: dragged, before: module)
                    }
                }
                return true
            }
    }

    private var modules: [PanelModule] { settings.settings.panel.visibleModules }

    /// The module open now, which decides the tab Activity Monitor opens on.
    private var openModule: PanelModule? {
        let collapsed = layout?.collapsedModulesOverride ?? settings.settings.panel.collapsedModules
        return modules.first { !collapsed.contains($0) }
    }

    private var insight: PanelInsight {
        PanelInsight.make(modules: modules, engine: engine,
                          formatter: MetricFormatter(settings: settings.settings.general))
    }

    /// Opens the module the insight is about, unless it already is.
    private func open(_ module: PanelModule) {
        let collapsed = layout?.collapsedModulesOverride ?? settings.settings.panel.collapsedModules
        guard collapsed.contains(module) else { return }
        if let toggle = layout?.toggleModule {
            toggle(module)
        } else {
            settings.update { s in s.panel.collapsedModules = s.panel.collapsedModules(toggling: module) }
        }
    }

    /// Wide enough for the longest module name, so every sparkline starts at one x.
    private var nameColumnWidth: CGFloat {
        let font = NSFont.systemFont(ofSize: 12)
        let widest = modules.map {
            ($0.label as NSString).size(withAttributes: [.font: font]).width
        }.max() ?? 0
        return ceil(widest)
    }

    /// One width for every row's qualifier column, from the captions on screen now.
    private var captionColumnWidth: CGFloat {
        let formatter = MetricFormatter(settings: settings.settings.general)
        return PanelSummary.captionColumnWidth(for: modules.map {
            PanelSummary.make(for: $0, engine: engine, formatter: formatter)
        })
    }

}

enum PanelTab: Hashable { case now, today }

private struct PanelInitialTabKey: EnvironmentKey {
    static let defaultValue = PanelTab.now
}

extension EnvironmentValues {
    /// The tab the panel opens on. Now, except in renders that show Today.
    var panelInitialTab: PanelTab {
        get { self[PanelInitialTabKey.self] }
        set { self[PanelInitialTabKey.self] = newValue }
    }
}

/// The panel's modules sorted into a few cards by what they measure.
///
/// Nine rows in one list read as a table; four short groups read as a dashboard, and
/// the eye finds Battery by going to the card about power. Within a card the modules
/// keep the user's order, and the cards come in the order of their first module.
enum PanelGroup: Hashable {
    case compute, io, power, system

    var title: String {
        switch self {
        case .compute: return "Compute"
        case .io: return "Network & storage"
        case .power: return "Power & heat"
        case .system: return "System"
        }
    }

    init(_ module: PanelModule) {
        switch module {
        case .cpu, .memory, .gpu: self = .compute
        case .network, .disk: self = .io
        case .battery, .thermal: self = .power
        case .processes, .system: self = .system
        }
    }

    struct Entry: Equatable {
        var group: PanelGroup
        var modules: [PanelModule]
    }

    static func arrange(_ modules: [PanelModule]) -> [Entry] {
        var entries: [Entry] = []
        for module in modules {
            let group = PanelGroup(module)
            if let index = entries.firstIndex(where: { $0.group == group }) {
                entries[index].modules.append(module)
            } else {
                entries.append(Entry(group: group, modules: [module]))
            }
        }
        return entries
    }
}

/// A card's heading, set in the panel's inset so it lines up with the rows below.
struct PanelGroupLabel: View {
    let title: String

    init(_ title: String) { self.title = title }

    var body: some View {
        PanelSectionLabel(title)
            .padding(.horizontal, Design.Space.panelInset)
            .padding(.top, Design.Space.m)
    }
}

extension View {
    /// A raised pane inside the panel: a faint fill, a hairline rim and a lit top
    /// edge, which is how macOS 26 sets groups apart inside glass.
    func panelCard() -> some View {
        background(
            RoundedRectangle(cornerRadius: Design.Radius.card + 2, style: .continuous)
                .fill(Design.Palette.cardFill)
                .overlay(
                    RoundedRectangle(cornerRadius: Design.Radius.card + 2, style: .continuous)
                        .strokeBorder(Design.Palette.cardRim, lineWidth: Design.Space.hairline)
                )
        )
        .padding(.horizontal, Design.Space.s)
    }
}

/// Inset rule between modules. macOS insets its separators to the content margin so
/// they read as dividing the text, not as slicing the window in half.
///
/// A rule that is not wanted turns clear rather than disappearing. It reads identically
/// — a transparent hairline is nothing — but it costs the layout the same one point
/// whatever the modules around it are doing. Inserting and removing the view instead
/// meant a single toggle restructured the stack twice, because `separatorNeeded` looks
/// at both of a rule's neighbours: expanding a module flipped the rule above it and the
/// rule below it. Only the first module escaped, its leading rule being suppressed by
/// the `index > 0` test, which is exactly why every module except CPU jumped harder.
struct PanelSeparator: View {
    var isVisible = true

    var body: some View {
        Rectangle()
            .fill(isVisible ? Design.Palette.separator : .clear)
            .frame(height: Design.Space.hairline)
            .padding(.horizontal, Design.Space.panelInset)
            .accessibilityHidden(true)
    }
}

/// The whole of what a scheduled update does to the app until the user asks for more.
///
/// It sits above the modules rather than in the footer because it is news and the footer
/// is furniture, and it is one row rather than a banner because an update is not more
/// important than the readings the user opened the panel to see.
struct PanelUpdateRow: View {
    let update: PendingUpdate
    let install: @MainActor () -> Void

    /// A staged update wants a relaunch and nothing else, so the row says so instead
    /// of promising an install it has already done.
    private var headline: String {
        update.isReadyToInstall ? "μStats \(update.version) is ready" : "μStats \(update.version) is available"
    }

    private var action: String { update.isReadyToInstall ? "Restart" : "Install" }

    @State private var isHovering = false

    var body: some View {
        Button(action: install) {
            HStack(spacing: Design.Space.s) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.accent)
                Text(headline)
                    .font(Design.Text.label)
                    .foregroundStyle(Design.Palette.primaryText)
                Spacer(minLength: Design.Space.m)
                Text(action)
                    .font(Design.Text.caption)
                    .foregroundStyle(Design.Palette.accent)
            }
            .padding(.horizontal, Design.Space.panelInset)
            .padding(.vertical, Design.Space.m)
            .background(isHovering ? Design.Palette.track : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                isHovering = hovering
            }
        }
        .accessibilityLabel(headline)
        .accessibilityHint(update.isReadyToInstall ? "Relaunches μStats into the new version"
                                                   : "Opens the updater to install it")
    }
}

/// The top of the panel: the Now/Today switch in the middle and Settings at the
/// right. Quit and Activity Monitor live elsewhere (the status item's menu, and
/// Option-click), so the panel spends its height on readings.
struct PanelHeaderView: View {
    @Binding var tab: PanelTab
    var showsTabs: Bool
    /// The readings stopped arriving: the Mac just woke, or sampling is stuck. Said
    /// here rather than by greying the numbers, which reads as disabled.
    var isStale = false

    @Environment(\.panelActions) private var actions
    @State private var isHovering = false

    var body: some View {
        ZStack {
            if showsTabs {
                Picker("View", selection: $tab) {
                    Text("Now").tag(PanelTab.now)
                    Text("Today").tag(PanelTab.today)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 160)
            }
            HStack(spacing: Design.Space.xs) {
                if isStale {
                    Text("Updating…")
                        .font(Design.Text.caption)
                        .foregroundStyle(Design.Palette.tertiaryText)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Button(action: actions.openSettings) {
                    Image(systemName: "gearshape")
                        .font(.system(size: 13, weight: .regular))
                        .foregroundStyle(isHovering ? Design.Palette.primaryText : Design.Palette.secondaryText)
                        .frame(width: 26, height: 22)
                        .background(
                            RoundedRectangle(cornerRadius: Design.Radius.control, style: .continuous)
                                .fill(isHovering ? Design.Palette.track : .clear)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .keyboardShortcut(",", modifiers: .command)
                .help("Settings")
                .accessibilityLabel("Settings")
                .onHover { hovering in
                    withAnimation(Design.Motion.respectingAccessibility(Design.Motion.hover)) {
                        isHovering = hovering
                    }
                }
            }
        }
        // ⌘Q still quits from the open panel, with nothing on screen for it.
        .background {
            Button("Quit", action: actions.quit)
                .keyboardShortcut("q", modifiers: .command)
                .hidden()
        }
        .padding(.horizontal, Design.Space.m)
        .padding(.top, Design.Space.m)
    }
}

