import SwiftUI

/// The moustache in μStats. "mu-stats" said aloud is half a moustache already, so
/// it turns up in places nobody is told about: on the About logo after seven clicks,
/// in the menu bar on World Moustache Day, and growing through November.
public enum Moustache {
    /// Width over height of the drawing's box.
    public static let aspect: CGFloat = 2.4

    /// The right half, as cubic segments from the top of the middle round the curl
    /// to the bottom of the middle, in a 24 by 10 box with y pointing down. The left
    /// half is this mirrored, so the two sides can never drift apart.
    private static let rightHalf: [(c1: CGPoint, c2: CGPoint, end: CGPoint)] = [
        (CGPoint(x: 13.6, y: 1.2), CGPoint(x: 16.6, y: 1.4), CGPoint(x: 18.4, y: 3.6)),
        (CGPoint(x: 19.6, y: 5.0), CGPoint(x: 21.6, y: 5.0), CGPoint(x: 22.2, y: 3.4)),
        (CGPoint(x: 22.5, y: 2.6), CGPoint(x: 22.2, y: 1.8), CGPoint(x: 21.4, y: 1.7)),
        (CGPoint(x: 23.4, y: 1.0), CGPoint(x: 24.4, y: 4.6), CGPoint(x: 22.0, y: 6.6)),
        (CGPoint(x: 19.6, y: 8.6), CGPoint(x: 15.6, y: 8.0), CGPoint(x: 12.0, y: 5.8)),
    ]
    private static let top = CGPoint(x: 12, y: 3)

    /// The outline fitted to `rect`. `yUp` is for a Core Graphics context that has
    /// not been flipped, where the box has to be turned over to stay the right way up.
    public static func path(in rect: CGRect, yUp: Bool = false) -> CGPath {
        let sx = rect.width / 24, sy = rect.height / 10
        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: rect.minX + p.x * sx, y: yUp ? rect.maxY - p.y * sy : rect.minY + p.y * sy)
        }
        func mirror(_ p: CGPoint) -> CGPoint { place(CGPoint(x: 24 - p.x, y: p.y)) }

        let path = CGMutablePath()
        path.move(to: place(top))
        for segment in rightHalf {
            path.addCurve(to: place(segment.end), control1: place(segment.c1), control2: place(segment.c2))
        }
        let starts = [top] + rightHalf.map(\.end)
        for index in rightHalf.indices.reversed() {
            let segment = rightHalf[index]
            path.addCurve(to: mirror(starts[index]), control1: mirror(segment.c2), control2: mirror(segment.c1))
        }
        path.closeSubpath()
        return path
    }

    /// 26 September, World Moustache Day, in the user's own calendar.
    public static func isDay(_ date: Date = Date(), calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.month, .day], from: date)
        return parts.month == 9 && parts.day == 26
    }

    /// How much moustache the menu bar wears today, 0 for none and 1 for all of it.
    ///
    /// Full on World Moustache Day. Through November it grows a little each day, the
    /// way the month is meant to go: about a third on the 1st, all of it on the 30th.
    /// It never starts smaller than that, because below it the menu bar shows a smudge.
    public static func growth(on date: Date = Date(), calendar: Calendar = .current) -> Double {
        if isDay(date, calendar: calendar) { return 1 }
        let parts = calendar.dateComponents([.month, .day], from: date)
        guard parts.month == 11, let day = parts.day else { return 0 }
        return 0.35 + 0.65 * Double(min(max(day, 1), 30) - 1) / 29
    }
}

public struct MoustacheShape: Shape {
    public init() {}

    public func path(in rect: CGRect) -> Path {
        Path(Moustache.path(in: rect))
    }
}
