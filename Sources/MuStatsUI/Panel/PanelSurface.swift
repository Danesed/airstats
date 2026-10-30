import SwiftUI
import AppKit

/// The panel's glass, drawn by SwiftUI so it can change height without the window.
///
/// The glass used to be the window's own content view, so the panel could only grow
/// by resizing the window, and AppKit animates a window frame on the main thread:
/// each step lays out the whole tree, resizes the glass and asks the window server
/// for a new surface. On a 120 Hz display a 180 ms open drew 7 to 15 of its 22
/// frames. Now, while the panel changes height, the window is held at all the room
/// below the status item, transparent, and the surface hugs its content inside it,
/// so a module opening or a tab changing is an ordinary SwiftUI animation: nothing
/// has to be measured before it starts, and a second click retargets the one in
/// flight. The window is cut back to the surface once everything has settled.
struct PanelSurface<Content: View>: View {
    let layout: PanelLayoutState
    @ViewBuilder let content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
    }

    var body: some View {
        PanelHug {
            content
        }
        .clipShape(shape)
        .panelGlass(in: shape)
        // Asks for the whole window while one is held, so the hosting view never
        // sizes the window back down to the surface mid-flight.
        .frame(minHeight: layout.canvasHeight, maxHeight: .infinity, alignment: .top)
    }
}

/// As tall as its content, up to the height on offer.
///
/// Below the screen's ceiling the surface is exactly its content, whatever the window
/// around it; past it, the content's scroll view takes the height there is.
private struct PanelHug: Layout {
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let ideal = subview.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
        return CGSize(width: proposal.width ?? ideal.width,
                      height: min(ideal.height, proposal.height ?? ideal.height))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading,
                              proposal: ProposedViewSize(width: bounds.width, height: bounds.height))
    }
}

private extension View {
    @ViewBuilder
    func panelGlass(in shape: RoundedRectangle) -> some View {
        if #available(macOS 26.0, *) {
            glassEffect(.regular, in: shape)
        } else {
            background(PanelLegacyBackdrop().clipShape(shape))
        }
    }
}

/// The material and sheen the panel had before Liquid Glass.
private struct PanelLegacyBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> GlassBackdropView {
        // Active rather than following the window: the panel is looked at while
        // another app is frontmost.
        GlassBackdropView(material: .hudWindow, cornerRadius: Design.Radius.panel, state: .active)
    }

    func updateNSView(_ view: GlassBackdropView, context: Context) {}
}
