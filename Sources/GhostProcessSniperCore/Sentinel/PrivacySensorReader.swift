import CoreAudio
import CoreMediaIO
import Darwin
import Foundation

/// Reads whether the microphone and cameras are in use. Reading never opens
/// a device and needs no permission: Core Audio lists which processes are
/// recording (macOS 14+), CoreMediaIO only whether a camera is running.
enum PrivacySensorReader {
    static func read(names: (Int32) -> String?) -> PrivacySensorState {
        var state = PrivacySensorState(available: true)
        let recorders = audioInputProcesses()
        state.microphoneUsers = recorders
            .filter { $0 != getpid() }
            .map { pid in
                let name = names(pid) ?? processName(pid) ?? "pid \(pid)"
                // The path is read only for the one name that could be passive: no cost for other recorders.
                let passive = name == passiveClientName && isPassiveClient(name: name, path: executablePath(pid))
                return PrivacySensorUser(pid: pid, name: systemAudioClients[name] ?? name, isPassive: passive)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        state.microphoneActive = !state.microphoneUsers.isEmpty || defaultInputIsRunning()
        let cameras = runningCameras()
        state.cameraActive = !cameras.isEmpty
        state.cameraDeviceNames = cameras
        return state
    }

    // MARK: - Microphone

    /// The daemon that holds the microphone open all day, waiting for "Hey Siri".
    static let passiveClientName = "corespeechd"
    static let passiveClientPath = "/System/Library/PrivateFrameworks/CoreSpeech.framework/corespeechd"

    /// Whether a client is Apple's wake-phrase listener, which records nothing
    /// until it hears the phrase. A name alone proves nothing (any program can
    /// be called corespeechd), so the file it runs must be the one in the
    /// sealed system volume, read from the kernel; anything else stays an
    /// ordinary recorder, orange tile included.
    static func isPassiveClient(name: String, path: String?) -> Bool {
        name == passiveClientName && path == passiveClientPath
    }

    /// macOS services that hold the microphone, named for what they do.
    static let systemAudioClients: [String: String] = [
        "corespeechd": "Siri (listening for \u{201C}Hey Siri\u{201D})",
        "avconferenced": "FaceTime",
        "callservicesd": "Phone calls",
        "com.apple.SpeechRecognitionCore.speechrecognitiond": "Dictation",
        "speechrecognitiond": "Dictation",
        "VoiceOver": "VoiceOver",
    ]

    private static func audioInputProcesses() -> [Int32] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &objects) == noErr else { return [] }

        var pids: [Int32] = []
        for object in objects {
            guard uint32Property(object, kAudioProcessPropertyIsRunningInput) == 1,
                  let pid = int32Property(object, kAudioProcessPropertyPID), pid > 0 else { continue }
            pids.append(pid)
        }
        return pids
    }

    private static func defaultInputIsRunning() -> Bool {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        return uint32Property(device, kAudioDevicePropertyDeviceIsRunningSomewhere) == 1
    }

    private static func uint32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    private static func int32Property(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Int32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Int32 = 0
        var size = UInt32(MemoryLayout<Int32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    // MARK: - Camera

    private static func runningCameras() -> [String] {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return [] }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return [] }

        var running: [String] = []
        for device in devices {
            var runningAddress = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard)
            )
            var isRunning: UInt32 = 0
            var readSize: UInt32 = 0
            guard CMIOObjectGetPropertyData(device, &runningAddress, 0, nil, UInt32(MemoryLayout<UInt32>.size),
                                            &readSize, &isRunning) == 0, isRunning != 0 else { continue }
            running.append(cameraName(device) ?? "Camera")
        }
        return running
    }

    private static func cameraName(_ device: CMIOObjectID) -> String? {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOObjectPropertyName),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain)
        )
        var name: Unmanaged<CFString>?
        var used: UInt32 = 0
        let status = withUnsafeMutablePointer(to: &name) { pointer in
            CMIOObjectGetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<CFString?>.size), &used, pointer)
        }
        guard status == 0, let name else { return nil }
        return name.takeRetainedValue() as String
    }

    private static func executablePath(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: 4096)
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    private static func processName(_ pid: Int32) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXCOMLEN) * 2 + 1)
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}

/// Re-reads the sensors only when Core Audio or CoreMediaIO report a change:
/// a device starting or stopping, a process gaining or losing an audio
/// client, a camera appearing. Idle, it costs nothing; a slow timer covers
/// any listener macOS fails to call.
final class PrivacySensorMonitor: @unchecked Sendable {
    private let queue = DispatchQueue(label: "GhostProcessSniper.sentinel.sensors", qos: .utility)
    private let onChange: @Sendable () -> Void
    private let lock = NSLock()
    private var dirty = true
    private var lastRead = Date.distantPast
    private var state = PrivacySensorState.unknown
    private var installed = false
    /// Listeners are registered once; the fallback re-read is rare.
    static let fallbackInterval: TimeInterval = 60

    init(onChange: @escaping @Sendable () -> Void = {}) {
        self.onChange = onChange
    }

    func start() {
        queue.async { [self] in
            guard !installed else { return }
            installed = true
            installAudioListeners()
            installCameraListeners()
        }
    }

    /// The current state, re-read only if something changed since.
    func current(names: (Int32) -> String?, now: Date = Date()) -> PrivacySensorState {
        let needsRead: Bool = lock.withLock {
            dirty || now.timeIntervalSince(lastRead) >= Self.fallbackInterval
        }
        guard needsRead else { return lock.withLock { state } }
        let read = PrivacySensorReader.read(names: names)
        lock.withLock {
            state = read
            dirty = false
            lastRead = now
        }
        return read
    }

    private func markDirty() {
        lock.withLock { dirty = true }
        onChange()
    }

    private func installAudioListeners() {
        let system = AudioObjectID(kAudioObjectSystemObject)
        for selector in [kAudioHardwarePropertyProcessObjectList, kAudioHardwarePropertyDefaultInputDevice] {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                     mElement: kAudioObjectPropertyElementMain)
            AudioObjectAddPropertyListenerBlock(system, &address, queue) { [weak self] _, _ in
                self?.markDirty()
                if selector == kAudioHardwarePropertyDefaultInputDevice { self?.watchDefaultInput() }
            }
        }
        watchDefaultInput()
    }

    private var inputListeners = ListenerSet<AudioDeviceID>()
    private var inputBlocks: [AudioDeviceID: AudioObjectPropertyListenerBlock] = [:]

    /// "Running somewhere" on the input device flips when any app starts or
    /// stops recording, including apps that were already audio clients. The
    /// device that stopped being the default loses its listener; before, each
    /// switch back added another one.
    private func watchDefaultInput() {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let read = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        let wanted: Set<AudioDeviceID> = read == noErr && device != 0 ? [device] : []
        inputListeners.sync(to: wanted, add: { device in
            var running = Self.runningAddress
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.markDirty() }
            guard AudioObjectAddPropertyListenerBlock(device, &running, queue, block) == noErr else { return false }
            inputBlocks[device] = block
            return true
        }, remove: { device in
            var running = Self.runningAddress
            if let block = inputBlocks.removeValue(forKey: device) {
                AudioObjectRemovePropertyListenerBlock(device, &running, queue, block)
            }
        })
    }

    private static let runningAddress = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    private func installCameraListeners() {
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var devicesAddress = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        CMIOObjectAddPropertyListenerBlock(system, &devicesAddress, queue) { [weak self] _, _ in
            self?.markDirty()
            self?.watchCameras()
        }
        watchCameras()
    }

    private var cameraListeners = ListenerSet<CMIOObjectID>()
    private var cameraBlocks: [CMIOObjectID: CMIOObjectPropertyListenerBlock] = [:]

    private func watchCameras() {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &address, 0, nil, &size) == 0, size > 0 else { return }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &address, 0, nil, size, &used, &devices) == 0 else { return }
        // Cameras that went away lose their listeners, and one that comes
        // back under a reused ID gets a fresh one instead of none.
        cameraListeners.sync(to: Set(devices.prefix(Int(used) / MemoryLayout<CMIOObjectID>.size)), add: { device in
            var running = Self.cameraRunningAddress
            let block: CMIOObjectPropertyListenerBlock = { [weak self] _, _ in self?.markDirty() }
            guard CMIOObjectAddPropertyListenerBlock(device, &running, queue, block) == 0 else { return false }
            cameraBlocks[device] = block
            return true
        }, remove: { device in
            var running = Self.cameraRunningAddress
            if let block = cameraBlocks.removeValue(forKey: device) {
                CMIOObjectRemovePropertyListenerBlock(device, &running, queue, block)
            }
        })
    }

    private static let cameraRunningAddress = CMIOObjectPropertyAddress(
        mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
        mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
        mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
}
