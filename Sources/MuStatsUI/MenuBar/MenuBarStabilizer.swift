import Foundation

/// Holds what the menu bar shows until a change is one a person could see.
///
/// The status item is drawn by the system's menu bar process, so every redraw is an
/// image shipped across to it, paid once per display. Counted over two minutes, nearly
/// every redraw was a change nobody could see: a bar moving by less than a pixel, a
/// network rate going from 340 to 352 KB/s. Those are held here; a real move goes
/// straight through, and so does any change of unit or of the item's state.
struct MenuBarStabilizer {
    /// About one pixel of a compact bar on a Retina display.
    static let levelStep = 0.04
    /// A rate has to move by almost a third before the number is redrawn: traffic
    /// swings by a fifth from one second to the next with nothing happening.
    static let rateShare = 0.3
    /// Below this, in the same unit, a rate's change is background chatter.
    static let rateFloor = 30.0

    private var shown: [UUID: MenuBarItemRender] = [:]

    mutating func apply(_ model: inout MenuBarRenderModel) {
        var next: [UUID: MenuBarItemRender] = [:]
        for index in model.items.indices {
            var item = model.items[index]
            if let previous = shown[item.id], previous.style == item.style,
               previous.isUnavailable == item.isUnavailable {
                if let old = previous.level, let new = item.level, abs(new - old) < Self.levelStep {
                    item.level = old
                }
                if Self.isSmallChange(previous.primary, item.primary)
                    && Self.isSmallChange(previous.secondary, item.secondary) {
                    item.primary = previous.primary
                    item.secondary = previous.secondary
                }
            }
            model.items[index] = item
            next[item.id] = item
        }
        shown = next
    }

    /// Two readings of a rate in the same unit that differ by too little to matter.
    /// Anything that is not a rate (a percentage, a temperature, which have their
    /// own steadying) is never held.
    static func isSmallChange(_ a: MenuBarLine?, _ b: MenuBarLine?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        if a.valueText == b.valueText { return a.series == b.series }
        guard let (x, unitA) = split(a.valueText), let (y, unitB) = split(b.valueText),
              unitA == unitB, unitA.hasSuffix("B") || unitA.hasSuffix("/s") || unitA.hasSuffix("bps")
        else { return false }
        let delta = abs(x - y)
        return delta < rateFloor || delta / max(x, y) < rateShare
    }

    private static func split(_ text: String) -> (Double, String)? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        let number = trimmed.prefix { $0.isNumber || $0 == "." || $0 == "," }
        guard !number.isEmpty, let value = Double(number.replacingOccurrences(of: ",", with: ".")) else { return nil }
        return (value, trimmed.dropFirst(number.count).trimmingCharacters(in: .whitespaces))
    }
}
