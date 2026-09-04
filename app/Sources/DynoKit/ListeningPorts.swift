import Darwin
import Foundation

/// Finds the TCP ports a process is listening on, so a local model server can
/// be discovered wherever the user put it rather than only on a default port.
enum ListeningPorts {
    // sys/proc_info.h constants that Swift does not surface.
    private static let listFDs: Int32 = 1
    private static let socketFDType: UInt32 = 2
    private static let fdSocketInfo: Int32 = 3
    private static let socketKindTCP: Int32 = 2
    private static let tcpStateListen: Int32 = 1

    static func forProcess(_ pid: Int32) -> [UInt16] {
        let bufferSize = proc_pidinfo(pid, listFDs, 0, nil, 0)
        guard bufferSize > 0 else { return [] }

        let stride = MemoryLayout<proc_fdinfo>.stride
        var descriptors = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bufferSize) / stride)
        let written = proc_pidinfo(pid, listFDs, 0, &descriptors, bufferSize)
        guard written > 0 else { return [] }
        descriptors = Array(descriptors.prefix(Int(written) / stride))

        var ports: Set<UInt16> = []
        for descriptor in descriptors where descriptor.proc_fdtype == socketFDType {
            var info = socket_fdinfo()
            let size = proc_pidfdinfo(
                pid, descriptor.proc_fd, fdSocketInfo, &info,
                Int32(MemoryLayout<socket_fdinfo>.size)
            )
            guard size == Int32(MemoryLayout<socket_fdinfo>.size),
                  info.psi.soi_kind == socketKindTCP
            else { continue }

            let tcp = info.psi.soi_proto.pri_tcp
            guard tcp.tcpsi_state == tcpStateListen else { continue }
            // insi_lport is held in network byte order.
            let port = UInt16(truncatingIfNeeded: tcp.tcpsi_ini.insi_lport).bigEndian
            if port > 0 { ports.insert(port) }
        }
        return ports.sorted()
    }
}

/// Test seam for the command-line probe.
public enum ListeningPortsProbe {
    public static func forProcess(_ pid: Int32) -> [UInt16] { ListeningPorts.forProcess(pid) }
}
