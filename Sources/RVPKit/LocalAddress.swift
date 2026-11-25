import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Finds the local IPv4 address the OS would use to reach a host. This is the
/// address we advertise in the `Call-Back` header, so it must be reachable from
/// the Exchange server (same LAN or VPN).
enum LocalAddress {
    static func outboundIPv4(toward host: String, port: UInt16) -> String? {
        var hints = addrinfo()
        hints.ai_family = AF_INET
        hints.ai_socktype = SOCK_DGRAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else { return nil }
        defer { freeaddrinfo(res) }

        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        defer { close(fd) }

        // UDP connect sends nothing; it only picks a route and source address.
        guard connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen) == 0 else { return nil }

        var local = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) }
        }
        guard ok == 0 else { return nil }

        var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        var addr = local.sin_addr
        guard inet_ntop(AF_INET, &addr, &buf, socklen_t(INET_ADDRSTRLEN)) != nil else { return nil }
        return String(cString: buf)
    }
}
