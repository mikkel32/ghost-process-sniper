import Foundation

/// Reads a process's listening TCP ports with the sampler's libproc reader,
/// so the radar and the stop verification agree on what a server holds. Only
/// sockets in the LISTEN state count, so a client connection to the port is
/// not mistaken for a server.
public struct DarwinListeningPortProbe: ListeningPortProbing {
    public init() {}

    public func ports(pid: Int32) -> Set<Int>? {
        ListeningSocketReader.listeningTCPPorts(pid: pid)
    }
}
