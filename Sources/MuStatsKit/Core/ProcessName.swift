import Darwin

/// The short name the kernel has for a pid, the one `ProcessRow.name` holds.
public enum ProcessName {
    public static func of(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 256)
        let length = proc_name(pid, &buffer, UInt32(buffer.count))
        guard length > 0 else { return nil }
        return String(cString: buffer)
    }
}
