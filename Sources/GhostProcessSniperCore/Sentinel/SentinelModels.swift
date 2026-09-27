import Foundation

/// How much a finding deserves attention. Every level below `dangerous` is
/// also produced by legitimate software, so the UI always shows the evidence
/// and never acts on its own.
public enum SentinelSeverity: Int, Comparable, Codable, Sendable, CaseIterable {
    /// Context only: shown in the launch feed, never as a finding.
    case info = 0
    /// Worth a look; common in legitimate tools too.
    case notable = 1
    /// Unusual for normal use; review what launched it.
    case suspicious = 2
    /// Matches how malware behaves on macOS; act now.
    case dangerous = 3

    public static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .info: "Info"
        case .notable: "Notable"
        case .suspicious: "Suspicious"
        case .dangerous: "Dangerous"
        }
    }

    public var systemImage: String {
        switch self {
        case .info: "info.circle"
        case .notable: "eye"
        case .suspicious: "exclamationmark.triangle"
        case .dangerous: "exclamationmark.octagon.fill"
        }
    }
}

/// One kind of evidence. Kinds are stable so a user can trust a pattern.
public enum SentinelSignalKind: String, Codable, Sendable, CaseIterable {
    case appSpawnedShell
    case downloadAndExecute
    case encodedPayload
    case passwordPrompt
    case credentialAccess
    case quarantineRemoval
    case persistence
    case reverseShell
    case tunnel
    case cryptoMiner
    case screenCapture
    case cameraCapture
    case temporaryLocation
    case hiddenLocation
    case deletedExecutable
    case masquerade
    case unsigned
    case adHocSigned
    case invalidSignature
    case downloadedExecutable
    case microphoneInUse
    case shortLived

    public var title: String {
        switch self {
        case .appSpawnedShell: "Launched by an app that should not run commands"
        case .downloadAndExecute: "Downloads and runs code"
        case .encodedPayload: "Hides its command in encoded text"
        case .passwordPrompt: "Asks for your password"
        case .credentialAccess: "Reads saved passwords or cookies"
        case .quarantineRemoval: "Removes macOS download protection"
        case .persistence: "Sets itself to start automatically"
        case .reverseShell: "Hands a shell to another computer"
        case .tunnel: "Opens a tunnel to the internet"
        case .cryptoMiner: "Looks like a crypto miner"
        case .screenCapture: "Captures the screen"
        case .cameraCapture: "Captures the camera"
        case .temporaryLocation: "Runs from a temporary folder"
        case .hiddenLocation: "Runs from a hidden or shared folder"
        case .deletedExecutable: "Its program file was deleted"
        case .masquerade: "Pretends to be a system process"
        case .unsigned: "Not code-signed"
        case .adHocSigned: "Signed without a developer identity"
        case .invalidSignature: "Signature does not match its code"
        case .downloadedExecutable: "Downloaded from the internet"
        case .microphoneInUse: "Using the microphone"
        case .shortLived: "Ran for under a second"
        }
    }

    public var systemImage: String {
        switch self {
        case .appSpawnedShell: "arrow.triangle.branch"
        case .downloadAndExecute: "arrow.down.circle"
        case .encodedPayload: "lock.doc"
        case .passwordPrompt: "key.horizontal"
        case .credentialAccess: "key"
        case .quarantineRemoval: "shield.slash"
        case .persistence: "arrow.clockwise.circle"
        case .reverseShell: "terminal"
        case .tunnel: "network"
        case .cryptoMiner: "bitcoinsign.circle"
        case .screenCapture: "rectangle.dashed.badge.record"
        case .cameraCapture: "video"
        case .temporaryLocation: "clock.arrow.circlepath"
        case .hiddenLocation: "eye.slash"
        case .deletedExecutable: "trash"
        case .masquerade: "theatermasks"
        case .unsigned: "signature"
        case .adHocSigned: "signature"
        case .invalidSignature: "xmark.seal"
        case .downloadedExecutable: "globe"
        case .microphoneInUse: "mic"
        case .shortLived: "bolt"
        }
    }
}

public struct SentinelSignal: Hashable, Codable, Sendable {
    public let kind: SentinelSignalKind
    public let severity: SentinelSeverity
    /// One plain sentence about what was seen.
    public let detail: String
    /// The exact text that matched, when there is one.
    public let evidence: String?

    public init(_ kind: SentinelSignalKind, _ severity: SentinelSeverity, _ detail: String, evidence: String? = nil) {
        self.kind = kind
        self.severity = severity
        self.detail = detail
        self.evidence = evidence
    }
}

/// One step of "who launched whom", oldest ancestor first.
public struct SentinelLineageNode: Hashable, Codable, Sendable {
    public let pid: Int32
    public let name: String
    public let executablePath: String

    public init(pid: Int32, name: String, executablePath: String) {
        self.pid = pid
        self.name = name
        self.executablePath = executablePath
    }

    /// The app name for bundle members ("Google Chrome"), else the process name.
    public var displayName: String {
        SentinelCatalog.appName(forPath: executablePath) ?? name
    }
}

/// What the Security framework says about an executable.
public struct CodeSigningSummary: Hashable, Codable, Sendable {
    public enum Authority: String, Codable, Sendable {
        case apple
        case appStore
        case developerID
        case otherCertificate
        case adHoc
        case unsigned
        case invalid
    }

    public let authority: Authority
    public let teamIdentifier: String?
    public let signingIdentifier: String?

    public init(authority: Authority, teamIdentifier: String?, signingIdentifier: String?) {
        self.authority = authority
        self.teamIdentifier = teamIdentifier
        self.signingIdentifier = signingIdentifier
    }

    public var label: String {
        switch authority {
        case .apple: "Apple"
        case .appStore: "Mac App Store"
        case .developerID: teamIdentifier.map { "Developer ID (\($0))" } ?? "Developer ID"
        case .otherCertificate: "Certificate (not Developer ID)"
        case .adHoc: "Ad hoc (no identity)"
        case .unsigned: "Unsigned"
        case .invalid: "Invalid signature"
        }
    }
}

/// A process worth attention, with everything needed to judge it.
public struct SentinelFinding: Identifiable, Hashable, Sendable {
    public let id: String
    public let identity: ProcessIdentity
    public let name: String
    public let executablePath: String
    public let commandLine: String
    public let lineage: [SentinelLineageNode]
    public let signals: [SentinelSignal]
    public let severity: SentinelSeverity
    public let headline: String
    public let recommendation: String
    public let firstSeen: Date
    public var lastSeen: Date
    public var isRunning: Bool
    public var signing: CodeSigningSummary?
    public var downloadedFrom: [String]
    /// Established connections ("203.0.113.7:443"), read while it runs.
    public var connections: [String] = []

    public init(
        identity: ProcessIdentity, name: String, executablePath: String, commandLine: String,
        lineage: [SentinelLineageNode], signals: [SentinelSignal], headline: String, recommendation: String,
        firstSeen: Date, lastSeen: Date, isRunning: Bool, signing: CodeSigningSummary?, downloadedFrom: [String]
    ) {
        id = SentinelFinding.key(for: identity)
        self.identity = identity
        self.name = name
        self.executablePath = executablePath
        self.commandLine = commandLine
        self.lineage = lineage
        self.signals = signals
        severity = signals.map(\.severity).max() ?? .info
        self.headline = headline
        self.recommendation = recommendation
        self.firstSeen = firstSeen
        self.lastSeen = lastSeen
        self.isRunning = isRunning
        self.signing = signing
        self.downloadedFrom = downloadedFrom
    }

    public static func key(for identity: ProcessIdentity) -> String {
        "\(identity.pid)-\(identity.startTimeSeconds)-\(identity.startTimeMicroseconds)"
    }

    /// "Google Chrome › zsh › curl".
    public var lineageText: String {
        lineage.map(\.displayName).joined(separator: " › ")
    }
}

/// How a launch was noticed.
public enum LaunchEventSource: String, Codable, Sendable {
    /// The periodic scan saw a process it had not seen before.
    case scan
    /// A watched app forked it; noticed within milliseconds, even if it exited.
    case spawnWatch
}

/// One new process, in the order it appeared.
public struct LaunchEvent: Identifiable, Hashable, Sendable {
    public let id: String
    public let at: Date
    public let identity: ProcessIdentity
    public let name: String
    public let executablePath: String
    public let commandLine: String
    public let lineage: [SentinelLineageNode]
    public let severity: SentinelSeverity
    public let signalKinds: [SentinelSignalKind]
    public let source: LaunchEventSource
    public let isSystem: Bool
    /// Seconds it ran, when it had already exited when first read.
    public let exitedAfter: TimeInterval?

    public init(
        at: Date, identity: ProcessIdentity, name: String, executablePath: String, commandLine: String,
        lineage: [SentinelLineageNode], severity: SentinelSeverity, signalKinds: [SentinelSignalKind],
        source: LaunchEventSource, isSystem: Bool, exitedAfter: TimeInterval? = nil
    ) {
        id = SentinelFinding.key(for: identity)
        self.at = at
        self.identity = identity
        self.name = name
        self.executablePath = executablePath
        self.commandLine = commandLine
        self.lineage = lineage
        self.severity = severity
        self.signalKinds = signalKinds
        self.source = source
        self.isSystem = isSystem
        self.exitedAfter = exitedAfter
    }

    public var parentName: String? {
        lineage.dropLast().last?.displayName
    }
}

public struct PrivacySensorUser: Hashable, Sendable, Identifiable {
    public let pid: Int32
    public let name: String
    public var id: Int32 { pid }

    public init(pid: Int32, name: String) {
        self.pid = pid
        self.name = name
    }
}

/// What the microphone and camera are doing. macOS names the processes that
/// record audio (macOS 14 and later) but only says whether a camera is on.
public struct PrivacySensorState: Hashable, Sendable {
    public var microphoneUsers: [PrivacySensorUser]
    public var microphoneActive: Bool
    public var cameraActive: Bool
    public var cameraDeviceNames: [String]
    public var available: Bool

    public init(microphoneUsers: [PrivacySensorUser] = [], microphoneActive: Bool = false, cameraActive: Bool = false,
                cameraDeviceNames: [String] = [], available: Bool = false) {
        self.microphoneUsers = microphoneUsers
        self.microphoneActive = microphoneActive
        self.cameraActive = cameraActive
        self.cameraDeviceNames = cameraDeviceNames
        self.available = available
    }

    public static let unknown = PrivacySensorState()
}

/// Everything the Security section shows. `revision` changes whenever the
/// content does, so equality is cheap on every refresh.
public struct SentinelReport: Sendable {
    public var findings: [SentinelFinding]
    public var launches: [LaunchEvent]
    /// Launch agents and daemons: what starts automatically.
    public var launchItems: [LaunchItem]
    public var sensors: PrivacySensorState
    public var watchedAppNames: [String]
    public var launchesLastMinute: Int
    public var dismissedCount: Int
    public var revision: UInt64

    public init(findings: [SentinelFinding] = [], launches: [LaunchEvent] = [], launchItems: [LaunchItem] = [],
                sensors: PrivacySensorState = .unknown, watchedAppNames: [String] = [], launchesLastMinute: Int = 0,
                dismissedCount: Int = 0, revision: UInt64 = 0) {
        self.findings = findings
        self.launches = launches
        self.launchItems = launchItems
        self.sensors = sensors
        self.watchedAppNames = watchedAppNames
        self.launchesLastMinute = launchesLastMinute
        self.dismissedCount = dismissedCount
        self.revision = revision
    }

    public static let empty = SentinelReport()

    public var highestSeverity: SentinelSeverity? {
        findings.filter(\.isRunning).map(\.severity).max()
    }

    public var activeFindingCount: Int {
        findings.filter { $0.isRunning && $0.severity >= .suspicious }.count
    }

    public var flaggedLaunchItems: [LaunchItem] {
        launchItems.filter { $0.severity >= .suspicious }
    }

    /// Running processes and startup items that deserve a look now.
    public var attentionCount: Int {
        activeFindingCount + flaggedLaunchItems.count
    }
}

extension SentinelReport: Equatable {
    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.revision == rhs.revision
    }
}
