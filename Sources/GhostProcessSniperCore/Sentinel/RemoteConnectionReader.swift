import Darwin
import Foundation

/// Where a process is connected: its established TCP connections, as
/// "203.0.113.7:443". Read only for findings, never for every process, so a
/// suspicious script's server shows up as evidence at no general cost.
enum RemoteConnectionReader {
    static let limit = 8

    static func connections(pid: Int32, includeLoopback: Bool = false) -> [String] {
        guard let descriptors = ListeningSocketReader.descriptors(pid: pid) else { return [] }
        var found: [String] = []
        for descriptor in descriptors where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else { continue }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Int32(TSI_S_ESTABLISHED),
                  let address = remoteAddress(tcp.tcpsi_ini, includeLoopback: includeLoopback) else { continue }
            if !found.contains(address) { found.append(address) }
            if found.count >= limit { break }
        }
        return found
    }

    private static func remoteAddress(_ socket: in_sockinfo, includeLoopback: Bool) -> String? {
        let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: socket.insi_fport)))
        guard port > 0 else { return nil }
        var faddr = socket.insi_faddr
        if socket.insi_vflag & UInt8(INI_IPV4) != 0 {
            var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var address = faddr.ina_46.i46a_addr4
            guard inet_ntop(AF_INET, &address, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return host == "127.0.0.1" && !includeLoopback ? nil : "\(host):\(port)"
        }
        if socket.insi_vflag & UInt8(INI_IPV6) != 0 {
            var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &faddr.ina_6, &buffer, socklen_t(buffer.count)) != nil else { return nil }
            let host = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            return host == "::1" && !includeLoopback ? nil : "[\(host)]:\(port)"
        }
        return nil
    }
}
