import Darwin

/// An integer sysctl, read at whatever width the kernel reports it.
///
/// Width-agnostic: `hw.memsize` is 64-bit while the core counts are 32-bit, and
/// reading either with the wrong width silently returns garbage.
func sysctlInt(_ name: String) -> Int? {
    var size = 0
    guard sysctlbyname(name, nil, &size, nil, 0) == 0 else { return nil }
    switch size {
    case MemoryLayout<Int32>.size:
        var value: Int32 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    case MemoryLayout<Int64>.size:
        var value: Int64 = 0
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    default:
        return nil
    }
}
