import SwiftUI

/// A reading with its unit set smaller than its number: "400" at full size, "KB/s"
/// beside it at about two thirds. The number is what the eye looks for; the unit only
/// has to be there when it is read.
enum UnitText {
    /// Units this splits off. Anything else is drawn whole, so "4d 7h" or "Charging"
    /// is never cut in two at a place that only looks like a number's end.
    private static let units: Set<String> = [
        "B", "KB", "MB", "GB", "TB", "B/s", "KB/s", "MB/s", "GB/s",
        "Kb/s", "Mb/s", "Gb/s", "bps", "Kbps", "Mbps", "Gbps",
        "%", "°C", "°F", "°", "W", "mW", "V", "mA", "mAh", "Wh",
        "GHz", "MHz", "ms", "rpm", "RPM",
    ]

    /// The number and its unit, or nil when `value` does not end in a known unit.
    static func split(_ value: String) -> (number: String, unit: String)? {
        guard let last = value.lastIndex(where: \.isNumber) else { return nil }
        let number = value[...last]
        let unit = value[value.index(after: last)...].trimmingCharacters(in: .whitespaces)
        guard !unit.isEmpty, units.contains(unit) else { return nil }
        // A space before the unit stays, so "400 KB/s" keeps its gap and "97%" stays tight.
        let gap = value[value.index(after: last)...].first == " " ? " " : ""
        return (String(number), gap + unit)
    }

    /// `value` as one `Text`, the unit at `unitScale` of `size`.
    static func text(_ value: String, size: CGFloat, weight: Font.Weight,
                     unitScale: CGFloat = 0.68) -> Text {
        let font = Font.system(size: size, weight: weight).monospacedDigit()
        guard let parts = split(value) else { return Text(value).font(font) }
        return Text(parts.number).font(font)
            + Text(parts.unit).font(.system(size: (size * unitScale).rounded(), weight: weight))
    }
}
