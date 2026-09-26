import Darwin
import Foundation

/// libproc and sysctl reads for the live process table.
struct NativeProcessProbeSource: ProcessProbeSource {
    func listPIDs(into buffer: inout [pid_t]) throws -> Int {
        var bytesWritten = 0
        while true {
            let bufferSize = buffer.count * MemoryLayout<pid_t>.stride
            bytesWritten = Int(buffer.withUnsafeMutableBufferPointer { pointer -> Int32 in
                proc_listpids(UInt32(PROC_ALL_PIDS), 0, pointer.baseAddress, Int32(bufferSize))
            })
            if bytesWritten < bufferSize || buffer.count >= 65_536 {
                break
            }
            buffer.append(contentsOf: repeatElement(0, count: buffer.count))
        }
        guard bytesWritten > 0 else {
            throw ProcessSamplerError.listFailed
        }
        return bytesWritten / MemoryLayout<pid_t>.stride
    }

    func bsd(_ pid: pid_t) -> ProbeBSDRead {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.stride)
        let result = proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size)
        guard result == size else {
            return result <= 0 && errno == EPERM ? .denied : .missing
        }
        let terminal = Self.terminalFields(info)
        return .record(ProbeBSD(
            pid: pid,
            parentPID: Int32(info.pbi_ppid),
            userID: info.pbi_uid,
            processGroupID: Int32(info.pbi_pgid),
            status: info.pbi_status,
            flags: info.pbi_flags,
            openFileCount: Int(info.pbi_nfiles),
            startTimeSeconds: info.pbi_start_tvsec,
            startTimeMicroseconds: info.pbi_start_tvusec,
            name: Self.kernelName(info),
            controllingTerminal: terminal.device,
            terminalForegroundGroupID: terminal.foregroundGroup
        ))
    }

    func usage(_ pid: pid_t) -> ProbeUsage? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, rebound)
            }
        }
        guard result == 0 else { return nil }
        return ProbeUsage(
            cpuSeconds: ProcessCPUTime.seconds(user: info.ri_user_time, system: info.ri_system_time),
            physicalFootprintBytes: info.ri_phys_footprint,
            residentBytes: info.ri_resident_size,
            wakeups: info.ri_pkg_idle_wkups &+ info.ri_interrupt_wkups,
            diskBytesWritten: info.ri_diskio_byteswritten,
            processStartAbsoluteTime: info.ri_proc_start_abstime
        )
    }

    func taskInfo(_ pid: pid_t) -> ProbeTask? {
        var info = proc_taskinfo()
        let size = Int32(MemoryLayout<proc_taskinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { return nil }
        return ProbeTask(threadCount: Int(info.pti_threadnum), virtualBytes: info.pti_virtual_size)
    }

    func sessionID(_ pid: pid_t) -> Int32? {
        let sid = getsid(pid)
        return sid > 0 ? Int32(sid) : nil
    }

    func executablePath(_ pid: pid_t) -> String {
        withUnsafeTemporaryAllocation(of: CChar.self, capacity: 4096) { buffer in
            buffer.initialize(repeating: 0)
            guard proc_pidpath(pid, buffer.baseAddress, UInt32(buffer.count)) > 0 else {
                return ""
            }
            return Self.string(from: UnsafeBufferPointer(buffer))
        }
    }

    func commandLine(_ pid: pid_t) -> String? {
        var mib = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, u_int(mib.count), nil, &size, nil, 0) == 0, size > 0 else {
            return nil
        }

        return withUnsafeTemporaryAllocation(of: CChar.self, capacity: size) { buffer in
            buffer.initialize(repeating: 0)
            guard sysctl(&mib, u_int(mib.count), buffer.baseAddress, &size, nil, 0) == 0, size > MemoryLayout<Int32>.size else {
                return nil
            }

            var argc: Int32 = 0
            memcpy(&argc, buffer.baseAddress, MemoryLayout<Int32>.size)

            // Skip the saved exec path and its padding to reach argv[0].
            var index = MemoryLayout<Int32>.size
            while index < size && buffer[index] != 0 { index += 1 }
            while index < size && buffer[index] == 0 { index += 1 }

            var arguments: [String] = []
            for _ in 0..<max(0, Int(argc)) {
                guard index < size else { break }
                let start = index
                while index < size && buffer[index] != 0 { index += 1 }
                if index > start, let base = buffer.baseAddress {
                    let bytes = UnsafeRawBufferPointer(start: base.advanced(by: start), count: index - start)
                    arguments.append(String(decoding: bytes, as: UTF8.self))
                }
                index += 1
            }

            return arguments.isEmpty ? nil : arguments.joined(separator: " ")
        }
    }

    func forensics(_ pid: pid_t) -> (forensics: ProcessForensics, expensiveCallCount: Int) {
        var notes: [String] = []
        var expensiveCallCount = 2

        let vnode = vnodePaths(for: pid)
        if vnode == nil {
            notes.append("cwd unavailable")
        }

        let descriptors = ListeningSocketReader.descriptors(pid: pid)
        if descriptors == nil {
            notes.append("file descriptors unavailable")
        }
        let sockets = descriptors.map { ListeningSocketReader.sockets(pid: pid, descriptors: $0) }
        expensiveCallCount += sockets?.socketCount ?? 0

        let forensics = ProcessForensics(
            currentDirectory: vnode?.currentDirectory,
            rootDirectory: vnode?.rootDirectory,
            openFileCount: descriptors?.count,
            socketCount: sockets?.socketCount,
            listeningPorts: ListeningSocketReader.storedPorts(sockets?.listeningPorts ?? []),
            isPartial: vnode == nil || descriptors == nil,
            notes: notes
        )
        return (forensics, expensiveCallCount)
    }

    func listeningPorts(_ pid: pid_t) -> Set<Int>? {
        ListeningSocketReader.listeningTCPPorts(pid: pid)
    }

    func now() -> UInt64 {
        DispatchTime.now().uptimeNanoseconds
    }

    var effectiveUserID: UInt32 {
        UInt32(geteuid())
    }

    private func vnodePaths(for pid: pid_t) -> (currentDirectory: String?, rootDirectory: String?)? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.stride)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else {
            return nil
        }
        return (
            Self.tupleString(info.pvi_cdir.vip_path).ifNotEmpty,
            Self.tupleString(info.pvi_rdir.vip_path).ifNotEmpty
        )
    }

    /// e_tdev is NODEV (all ones) without a controlling terminal.
    private static func terminalFields(_ info: proc_bsdinfo) -> (device: UInt32?, foregroundGroup: Int32?) {
        #if os(macOS)
        guard info.e_tdev != UInt32.max else { return (nil, nil) }
        return (info.e_tdev, info.e_tpgid == 0 ? nil : Int32(bitPattern: info.e_tpgid))
        #else
        return (nil, nil)
        #endif
    }

    private static func kernelName(_ info: proc_bsdinfo) -> String {
        tupleString(info.pbi_name)
    }

    private static func string(from buffer: UnsafeBufferPointer<CChar>) -> String {
        let length = buffer.firstIndex(of: 0) ?? buffer.count
        return UnsafeBufferPointer(rebasing: buffer[..<length]).withMemoryRebound(to: UInt8.self) { bytes in
            String(decoding: bytes, as: UTF8.self)
        }
    }

    private static func tupleString<T>(_ tuple: T) -> String {
        var value = tuple
        return withUnsafeBytes(of: &value) { rawBuffer in
            let chars = rawBuffer.bindMemory(to: UInt8.self)
            let length = chars.firstIndex(of: 0) ?? chars.count
            return String(decoding: UnsafeBufferPointer(rebasing: chars[..<length]), as: UTF8.self)
        }
    }
}
