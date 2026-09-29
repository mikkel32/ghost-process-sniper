import Foundation
import IOKit.pwr_mgt

/// What a power assertion holds back.
public enum SleepAssertionEffect: String, Equatable, Sendable {
    /// The Mac cannot idle-sleep while this is held.
    case systemSleep
    /// The display stays on (and the Mac awake with it).
    case displaySleep
}

/// One active power assertion, as `pmset -g assertions` lists it.
public struct SleepAssertion: Equatable, Sendable {
    public let pid: Int32
    public let processName: String
    /// The raw type, such as "PreventUserIdleSystemSleep".
    public let type: String
    public let effect: SleepAssertionEffect
    /// The holder's own description, such as "Xcode running tests." or "Electron".
    public let name: String
    public let startedAt: Date?
    /// Set when a system daemon holds the assertion for an app, as coreaudiod
    /// does for the app playing or recording audio.
    public let onBehalfOfPID: Int32?

    public init(pid: Int32, processName: String, type: String, effect: SleepAssertionEffect, name: String,
                startedAt: Date?, onBehalfOfPID: Int32? = nil) {
        self.pid = pid
        self.processName = processName
        self.type = type
        self.effect = effect
        self.name = name
        self.startedAt = startedAt
        self.onBehalfOfPID = onBehalfOfPID
    }

    /// The process whose work the assertion serves.
    public var responsiblePID: Int32 { onBehalfOfPID ?? pid }

    /// Audio assertions name their device ("com.apple.audio.BuiltInSpeakerDevice.context…").
    public var isAudio: Bool { name.hasPrefix("com.apple.audio.") }

    /// Maps the assertion types that keep the Mac or its display awake; the
    /// rest (background tasks, push, user activity) are short and managed by
    /// macOS itself.
    static func effect(forType type: String) -> SleepAssertionEffect? {
        switch type {
        case "PreventUserIdleSystemSleep", "PreventSystemSleep", "NoIdleSleepAssertion", "DenySystemSleep":
            .systemSleep
        case "PreventUserIdleDisplaySleep", "NoDisplaySleepAssertion":
            .displaySleep
        default:
            nil
        }
    }

    /// Parses one entry of IOPMCopyAssertionsByProcess.
    static func parse(pid: Int32, entry: [String: Any]) -> SleepAssertion? {
        guard let type = entry["AssertType"] as? String, let effect = effect(forType: type) else { return nil }
        // Level 0 means the holder released it and powerd has not dropped it yet.
        if let level = entry["AssertLevel"] as? NSNumber, level.intValue == 0 { return nil }
        let behalf = (entry["AssertionOnBehalfOfPID"] as? NSNumber)?.int32Value
        return SleepAssertion(
            pid: pid,
            processName: entry["Process Name"] as? String ?? "",
            type: type,
            effect: effect,
            name: entry["AssertName"] as? String ?? "",
            startedAt: entry["AssertStartWhen"] as? Date,
            onBehalfOfPID: behalf.flatMap { $0 > 0 && $0 != pid ? $0 : nil }
        )
    }
}

public protocol SleepAssertionSource: Sendable {
    /// nil when powerd could not be asked; an empty list means nothing is held.
    func read() -> [SleepAssertion]?
}

/// Asks powerd for every process's assertions. One IPC round trip; no privileges.
public struct IOKitSleepAssertionSource: SleepAssertionSource {
    public init() {}

    public func read() -> [SleepAssertion]? {
        var unmanaged: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&unmanaged) == kIOReturnSuccess,
              let dictionary = unmanaged?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return nil }
        var assertions: [SleepAssertion] = []
        for (pid, entries) in dictionary {
            for entry in entries {
                if let assertion = SleepAssertion.parse(pid: pid.int32Value, entry: entry) {
                    assertions.append(assertion)
                }
            }
        }
        return assertions.sorted { ($0.pid, $0.type, $0.name) < ($1.pid, $1.type, $1.name) }
    }
}
