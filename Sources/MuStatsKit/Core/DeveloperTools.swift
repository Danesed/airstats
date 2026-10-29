import Foundation
import Darwin

/// A TCP port something on this Mac is listening on.
public struct ListeningPort: Sendable, Equatable, Identifiable {
    public var pid: Int32
    public var processName: String
    public var port: Int
    /// Bound to every interface rather than to the loopback: reachable from the
    /// network, which for a development server is usually not what was meant.
    public var isExposed: Bool

    public var id: String { "\(pid):\(port)" }

    public init(pid: Int32, processName: String, port: Int, isExposed: Bool) {
        self.pid = pid
        self.processName = processName
        self.port = port
        self.isExposed = isExposed
    }
}

/// The ports this user's processes listen on, read from the kernel's file tables.
///
/// About 7 ms for 900 processes, so it is read when someone looks and not before.
/// Only processes this user owns can be inspected, which is the set worth listing:
/// the development servers, databases and tools the user started.
public enum ListeningPorts {

    /// Ports in the dynamic range are almost all an app talking to its own helpers
    /// over the loopback. Listing them buries the dev server among forty of them.
    public static let dynamicRange = 49_152

    public static func current() -> [ListeningPort] {
        var pids = [pid_t](repeating: 0, count: 4096)
        let count = proc_listallpids(&pids, Int32(MemoryLayout<pid_t>.stride * pids.count))
        guard count > 0 else { return [] }
        var found: [String: ListeningPort] = [:]
        for pid in pids.prefix(Int(count)) where pid > 0 {
            for (port, exposed) in listening(pid) where port < dynamicRange {
                guard !isSystem(pid) else { break }
                let key = "\(pid):\(port)"
                let name = ProcessName.of(pid) ?? "pid \(pid)"
                let existing = found[key]
                found[key] = ListeningPort(pid: pid, processName: name, port: port,
                                           isExposed: exposed || (existing?.isExposed ?? false))
            }
        }
        return found.values.sorted { ($0.port, $0.pid) < ($1.port, $1.pid) }
    }

    /// The TCP sockets in LISTEN that `pid` holds, with whether each is bound to
    /// every interface.
    static func listening(_ pid: pid_t) -> [(Int, Bool)] {
        let size = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard size > 0 else { return [] }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(size) / MemoryLayout<proc_fdinfo>.stride)
        let read = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, size)
        guard read > 0 else { return [] }
        var result: [(Int, Bool)] = []
        for fd in fds.prefix(Int(read) / MemoryLayout<proc_fdinfo>.stride)
        where fd.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let length = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDSOCKETINFO, &info, length) == length,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_LISTEN) else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            result.append((port, isWildcard(tcp.tcpsi_ini)))
        }
        return result
    }

    private static func isWildcard(_ address: in_sockinfo) -> Bool {
        if address.insi_vflag & UInt8(INI_IPV6) != 0 {
            var v6 = address.insi_laddr.ina_6
            return withUnsafeBytes(of: &v6) { $0.allSatisfy { $0 == 0 } }
        }
        return address.insi_laddr.ina_46.i46a_addr4.s_addr == 0
    }

    /// The system's own listeners (AirPlay, Handoff) are not what this list is for.
    private static func isSystem(_ pid: pid_t) -> Bool {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return true }
        let path = String(cString: buffer)
        return path.hasPrefix("/System/") || path.hasPrefix("/usr/libexec/") || path.hasPrefix("/usr/sbin/")
    }
}

/// A container Docker is running, as its API describes it.
public struct DockerContainer: Sendable, Equatable, Identifiable, Decodable {
    public struct Port: Sendable, Equatable, Decodable {
        public var privatePort: Int
        public var publicPort: Int?

        enum CodingKeys: String, CodingKey {
            case privatePort = "PrivatePort", publicPort = "PublicPort"
        }
    }

    public var id: String
    public var names: [String]
    public var image: String
    public var state: String
    public var ports: [Port]

    /// "postgres" rather than "/postgres": the API keeps the slash Docker's own CLI drops.
    public var name: String {
        (names.first ?? id).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    enum CodingKeys: String, CodingKey {
        case id = "Id", names = "Names", image = "Image", state = "State", ports = "Ports"
    }
}

/// Space Docker holds on disk, from its own accounting.
public struct DockerDiskUsage: Sendable, Equatable {
    public var images: UInt64
    public var containers: UInt64
    public var volumes: UInt64
    public var buildCache: UInt64

    public var total: UInt64 { images + containers + volumes + buildCache }
}

/// Docker's API over its Unix socket: two GETs, made only while someone looks.
///
/// A plain HTTP/1.0 request on the socket, so the reply ends when the connection
/// closes and nothing here has to understand chunked encoding. Nothing runs, and no
/// socket is touched, unless Docker's socket exists.
public enum DockerAPI {

    /// Docker Desktop's socket first, then the classic one other runtimes provide.
    public static var socketPath: String? {
        let candidates = [FileManager.default.homeDirectoryForCurrentUser
                            .appendingPathComponent(".docker/run/docker.sock").path,
                          "/var/run/docker.sock"]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }

    public static func containers() -> [DockerContainer]? {
        guard let body = get("/containers/json") else { return nil }
        return try? JSONDecoder().decode([DockerContainer].self, from: body)
    }

    public static func diskUsage() -> DockerDiskUsage? {
        guard let body = get("/system/df"),
              let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] else { return nil }
        func sum(_ key: String, _ field: (([String: Any]) -> UInt64)) -> UInt64 {
            ((json[key] as? [[String: Any]]) ?? []).reduce(0) { $0 + field($1) }
        }
        let number: (Any?) -> UInt64 = { ($0 as? NSNumber)?.uint64Value ?? 0 }
        return DockerDiskUsage(
            images: number(json["LayersSize"]),
            containers: sum("Containers") { number($0["SizeRw"]) },
            volumes: sum("Volumes") { number(($0["UsageData"] as? [String: Any])?["Size"]) },
            buildCache: sum("BuildCache") { number($0["Size"]) })
    }

    /// The body of a GET, or nil when Docker is not running or did not answer in time.
    static func get(_ path: String, timeout: TimeInterval = 3) -> Data? {
        guard let socketPath else { return nil }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var tv = timeval(tv_sec: Int(timeout), tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard socketPath.utf8.count < capacity else { return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: socketPath.utf8)
        }
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { return nil }

        let request = "GET \(path) HTTP/1.0\r\nHost: docker\r\n\r\n"
        guard request.withCString({ write(fd, $0, strlen($0)) }) > 0 else { return nil }
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 16_384)
        while true {
            let count = read(fd, &buffer, buffer.count)
            if count <= 0 { break }
            response.append(buffer, count: count)
        }
        guard let split = response.range(of: Data("\r\n\r\n".utf8)),
              let status = String(data: response[..<split.lowerBound], encoding: .utf8),
              status.hasPrefix("HTTP/1.") , status.contains(" 200 ") else { return nil }
        return response[split.upperBound...]
    }
}

/// Is this a Mac someone develops on? Decides whether the developer readings are
/// shown before the user has said either way.
public enum DeveloperEnvironment {
    public static var isPresent: Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: "/Applications/Xcode.app")
            || fm.fileExists(atPath: "/opt/homebrew/bin/brew")
            || fm.fileExists(atPath: "/usr/local/bin/brew")
            || DockerAPI.socketPath != nil
    }
}
