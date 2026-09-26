import Darwin
import Foundation

/// Reads a process's listening TCP ports through libproc: its descriptors,
/// then the socket info of each socket. Only sockets in the LISTEN state
/// count, so a client connection to the port is not mistaken for a server.
public struct DarwinListeningPortProbe: ListeningPortProbing {
    /// TSI_S_LISTEN in <sys/proc_info.h>.
    private static let listenState: Int32 = 1

    public init() {}

    public func ports(pid: Int32) -> Set<Int>? {
        guard let descriptors = Self.descriptors(pid: pid) else { return nil }
        var ports: Set<Int> = []
        for descriptor in descriptors where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            var info = socket_fdinfo()
            let size = Int32(MemoryLayout<socket_fdinfo>.stride)
            guard proc_pidfdinfo(pid, descriptor.proc_fd, PROC_PIDFDSOCKETINFO, &info, size) == size,
                  info.psi.soi_kind == Int32(SOCKINFO_TCP) else {
                continue
            }
            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == Self.listenState else { continue }
            let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport)))
            if port > 0 { ports.insert(port) }
        }
        return ports
    }

    private static func descriptors(pid: Int32) -> [proc_fdinfo]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        // Room for descriptors opened between the two calls.
        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride + 16
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count * MemoryLayout<proc_fdinfo>.stride))
        }
        guard result > 0 else { return nil }
        return Array(descriptors.prefix(Int(result) / MemoryLayout<proc_fdinfo>.stride))
    }
}
