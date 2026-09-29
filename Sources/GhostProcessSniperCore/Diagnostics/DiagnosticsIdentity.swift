import Darwin
import Foundation

/// Which build and which Mac a report came from, so a bug report can be
/// reproduced without the reporter typing it out. Read when Copy Diagnostics
/// is pressed, never per tick. Hardware stays coarse (model, chip, memory);
/// no serial number and no machine name.
struct DiagnosticsIdentity: Equatable, Sendable {
    var appVersion: String?
    var appBuild: String?
    var systemVersion: String
    var hardwareModel: String
    var chip: String
    var memoryBytes: UInt64
    var coreCount: Int
    var lowPowerMode: Bool
    var thermalState: String
    var localeIdentifier: String

    /// A binary that was not built into the app bundle has no Info.plist,
    /// so `bundle` may hold no version at all.
    static func current(bundle: Bundle? = .main) -> DiagnosticsIdentity {
        let info = ProcessInfo.processInfo
        let thermal = switch info.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
        return DiagnosticsIdentity(
            appVersion: bundle?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String,
            appBuild: bundle?.object(forInfoDictionaryKey: "CFBundleVersion") as? String,
            systemVersion: info.operatingSystemVersionString,
            hardwareModel: sysctlString("hw.model"),
            chip: sysctlString("machdep.cpu.brand_string"),
            memoryBytes: info.physicalMemory,
            coreCount: info.processorCount,
            lowPowerMode: info.isLowPowerModeEnabled,
            thermalState: thermal,
            localeIdentifier: Locale.current.identifier
        )
    }

    var lines: [String] {
        let app: String
        if let appVersion {
            let build = appBuild.flatMap { $0 == appVersion ? nil : " (build \($0))" } ?? ""
            app = "Ghost Process Sniper \(appVersion)\(build)"
        } else {
            app = "unbundled build (no version)"
        }
        let mac = [hardwareModel, chip, RadarFormat.bytes(memoryBytes), "\(coreCount) cores"].filter { !$0.isEmpty }
        return [
            "App: \(app)",
            "macOS: \(systemVersion)",
            "Mac: \(mac.joined(separator: ", "))",
            "Power: Low Power Mode \(lowPowerMode ? "on" : "off"), thermal state \(thermalState)",
            "Locale: \(localeIdentifier)"
        ]
    }

    /// The settings in effect, and the limits they resolve to on this Mac
    /// right now: what explains why an alert fired on someone else's Mac.
    static func settingsLines(_ profile: ResolvedThresholdProfile) -> [String] {
        let settings = profile.effectiveSettings
        // Sensitivity only shapes automatic limits; custom ones are exact.
        let sensitivity = profile.isAdaptive ? ", \(settings.sensitivity.label) sensitivity" : ""
        return [
            "Detection: \(settings.detectionMode.label)\(sensitivity); limits: memory \(profile.memoryThresholdText), " +
                "CPU \(profile.cpuThresholdText), growth \(profile.leakThresholdText)",
            "Modes: \(settings.radarMode.label) radar, \(settings.performanceMode.label) performance, " +
                "adaptive performance \(settings.adaptivePerformance ? "on" : "off"), " +
                "family grouping \(settings.groupFamilies ? "on" : "off")"
        ]
    }

    /// Writes the home folder as `~`, so a pasted report does not carry the
    /// account name in the store's path or in a process path.
    static func redactingHome(in text: String, home: String = NSHomeDirectory()) -> String {
        // A root or empty home would rewrite every path in the report.
        guard home.count > 1 else { return text }
        // Not followed by a name character: `/Users/al` must leave `/Users/alice` alone.
        let pattern = NSRegularExpression.escapedPattern(for: home) + #"(?![\p{L}\p{N}._-])"#
        return text.replacingOccurrences(of: pattern, with: "~", options: .regularExpression)
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(decoding: bytes.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }
}
