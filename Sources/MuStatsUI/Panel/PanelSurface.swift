import SwiftUI
import AppKit

/// The panel's glass, drawn by SwiftUI so it can change height without the window.
///
/// The glass used to be the window's own content view, so the panel could only grow
/// by resizing the window, and AppKit animates a window frame on the main thread:
/// each step lays out the whole tree, resizes the glass and asks the window server
/// for a new surface. On a 120 Hz display a 180 ms open drew 7 to 15 of its 22
/// frames, with gaps up to 45 ms. Now the window is given the larger of the two
/// heights before anything moves, the surface animates inside it in one SwiftUI
/// transaction together with the content it reveals, and the window is cut to size
/// once the surface has arrived. The space below the surface is transparent, and
/// only exists for the length of the animation.
struct PanelSurface<Content: View>: View {
    let layout: PanelLayoutState
    @ViewBuilder let content: Content

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Design.Radius.panel, style: .continuous)
    }

    var body: some View {
        content
            .modifier(SurfaceHeight(height: layout.surfaceHeight ?? 0, isHeld: layout.surfaceHeight != nil,
                                    onFrame: layout.onSurfaceHeight))
            .clipShape(shape)
            .panelGlass(in: shape)
            // Asks for the whole window while one is held for a transition, so the
            // hosting view never sizes the window back down to the surface mid-flight.
            .frame(minHeight: layout.canvasHeight, maxHeight: .infinity, alignment: .top)
    }
}

/// The surface's height on each frame of a transition.
///
/// Animatable so SwiftUI hands it every interpolated height rather than only the
/// destination, which is all `onGeometryChange` reports, and the window needs each
/// one to keep its shadow on the surface.
private struct SurfaceHeight: ViewModifier, Animatable {
    var height: CGFloat
    var isHeld: Bool
    var onFrame: ((CGFloat) -> Void)?

    var animatableData: CGFloat {
        get { height }
        set { height = newValue }
    }

    func body(content: Content) -> some View {
        if isHeld, let onFrame {
            let height = height
            DispatchQueue.main.async { onFrame(height) }
        }
        return content.frame(height: isHeld ? height : nil, alignment: .top)
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
