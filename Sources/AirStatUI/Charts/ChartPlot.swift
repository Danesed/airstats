import SwiftUI
import AirStatKit

/// Path geometry the history charts share.
enum ChartPlot {
    /// Horizontal gridlines. `interiorOnly` omits the lines on the frame itself,
    /// which at sparkline height would draw a box around 28 points of chart.
    static func gridPath(in rect: CGRect, divisions: Int = 4, interiorOnly: Bool = false) -> Path {
        var path = Path()
        guard divisions > 0 else { return path }
        let steps = interiorOnly ? Array(1..<divisions) : Array(0...divisions)
        for step in steps {
            let y = rect.maxY - rect.height * CGFloat(step) / CGFloat(divisions)
            path.move(to: CGPoint(x: rect.minX, y: y))
            path.addLine(to: CGPoint(x: rect.maxX, y: y))
        }
        return path
    }
}

/// An already-built `Path`, wrapped so it can be filled, stroked and clipped as a view.
///
/// Every chart in the app draws through this. `Canvas` is the obvious tool for the job
/// and is the one thing that must not be used here: the first `Canvas` to render
/// anywhere in the process brings up SwiftUI's Metal renderer, and the GPU arena it
/// allocates is charged to the app and never handed back. Measured on an M3 Pro, one
/// `Canvas` in the panel took the process from 12 MB to 112 MB the first time the panel
/// was opened — 93 MB of `Owned physical footprint (unmapped) (graphics)` plus 3.5 MB
/// of `IOAccelerator` — and it stayed there for the rest of the session. The same
/// drawing expressed as shapes costs nothing measurable, because Core Animation
/// rasterises paths without ever touching the GPU renderer.
///
/// The path is built in the coordinate space of the view this is applied to, so its
/// points are absolute and `path(in:)` ignores the rect it is handed.
struct PlotShape: Shape {
    let built: Path

    init(_ built: Path) { self.built = built }

    func path(in rect: CGRect) -> Path { built }
}

/// The "nothing sampled yet" state: a baseline, drawn deliberately, so an empty chart
/// reads as a chart waiting for data rather than as a broken one.
struct EmptyBaseline: View {
    let rect: CGRect

    var body: some View {
        PlotShape(path)
            .stroke(Design.Palette.track,
                    style: StrokeStyle(lineWidth: Design.Chart.lineWidth, lineCap: .round,
                                       dash: [2, 4]))
    }

    private var path: Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.maxY - Design.Space.hairline))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - Design.Space.hairline))
        return path
    }
}

enum ChartLayout {

    /// Inset so a sample at the top of the domain draws its full stroke, and the
    /// end-of-line marker its full circle, instead of being sliced by the frame —
    /// the fixture waveform's spike exists to catch exactly that.
    ///
    /// The bottom is left flush: a filled area has to meet the baseline, and a value
    /// of zero is legitimately drawn as a line sitting on the floor.
    static let edgeInset: CGFloat = 2

    static func plotRect(in size: CGSize) -> CGRect {
        CGRect(x: edgeInset,
               y: edgeInset,
               width: max(size.width - edgeInset * 2, 0),
               height: max(size.height - edgeInset, 0))
    }

    /// The dot marking the newest sample at the right edge of a line.
    static func marker(at point: CGPoint, radius: CGFloat = 2) -> Path {
        Path(ellipseIn: CGRect(x: point.x - radius, y: point.y - radius,
                               width: radius * 2, height: radius * 2))
    }
}
