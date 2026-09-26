import Darwin
import Foundation

/// Which TCP ports a process is listening on: PROC_PIDLISTFDS, then
/// PROC_PIDFDSOCKETINFO for each socket. Only sockets in the LISTEN state
/// count, so outbound connections' ephemeral ports and UDP never show up as
/// ports a stop would free.
enum ListeningSocketReader {
    static func listeningTCPPorts(pid: Int32) -> Set<Int>? {
        guard let descriptors = descriptors(pid: pid) else { return nil }
        return sockets(pid: pid, descriptors: descriptors).listeningPorts
    }

    /// The host-order port of a listening TCP socket, else nil.
    static func listeningPort(kind: Int32, tcpState: Int32, localPort: Int32) -> Int? {
        guard kind == Int32(SOCKINFO_TCP), tcpState == Int32(TSI_S_LISTEN) else { return nil }
        let port = Int(UInt16(bigEndian: UInt16(truncatingIfNeeded: localPort)))
        return port > 0 ? port : nil
    }

    /// The ports forensics keep for display and search.
    static func displayPorts(_ ports: Set<Int>) -> [Int] {
        Array(ports.sorted().prefix(8))
    }

    static func descriptors(pid: Int32) -> [proc_fdinfo]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else {
            return nil
        }

        let count = Int(bytes) / MemoryLayout<proc_fdinfo>.stride
        guard count > 0 else {
            return []
        }

        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: count)
        let result = descriptors.withUnsafeMutableBufferPointer { buffer in
            proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress,
                         Int32(buffer.count * MemoryLayout<proc_fdinfo>.stride))
        }
        guard result > 0 else {
            return nil
        }
        descriptors.removeSubrange(min(count, Int(result) / MemoryLayout<proc_fdinfo>.stride)...)
        return descriptors
    }

    static func sockets(pid: Int32, descriptors: [proc_fdinfo]) -> (socketCount: Int, listeningPorts: Set<Int>) {
        var socketCount = 0
        var ports = Set<Int>()
        for descriptor in descriptors where descriptor.proc_fdtype == UInt32(PROX_FDTYPE_SOCKET) {
            socketCount += 1
            if let port = listeningPort(pid: pid, fd: descriptor.proc_fd) {
                ports.insert(port)
            }
        }
        return (socketCount, ports)
    }

    private static func listeningPort(pid: Int32, fd: Int32) -> Int? {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.stride)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else {
            return nil
        }
        let tcp = info.psi.soi_proto.pri_tcp
        return listeningPort(kind: info.psi.soi_kind, tcpState: tcp.tcpsi_state, localPort: tcp.tcpsi_ini.insi_lport)
    }
}
