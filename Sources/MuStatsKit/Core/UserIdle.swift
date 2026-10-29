import Foundation
import IOKit

/// How long since anyone touched the keyboard, the trackpad or the mouse.
///
/// Read from the HID system's own counter in the I/O registry: no event tap and no
/// Input Monitoring permission, one registry lookup per call.
public enum UserIdle {
    public static func seconds() -> TimeInterval? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOHIDSystem"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        guard let value = IORegistryEntryCreateCFProperty(service, "HIDIdleTime" as CFString,
                                                          kCFAllocatorDefault, 0)?.takeRetainedValue(),
              let nanoseconds = (value as? NSNumber)?.uint64Value else { return nil }
        return TimeInterval(nanoseconds) / 1_000_000_000
    }
}
