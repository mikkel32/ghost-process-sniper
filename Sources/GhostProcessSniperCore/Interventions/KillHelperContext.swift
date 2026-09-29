import Foundation

/// What a process is to the app it works for, read from its executable path
/// and name: a helper the app runs for its windows, or an XPC service an app
/// starts on demand. Stopping either costs the app part of its window, and
/// the app, not launchd, is what may start it again.
struct KillHelperContext: Equatable, Sendable {
    enum Role: Equatable, Sendable {
        /// Draws a window or a tab: a web page's process.
        case renderer
        case gpu
        case networking
        case other
    }

    let role: Role
    /// The app whose bundle holds it; nil for a service macOS itself ships.
    let appName: String?
    let isXPCService: Bool

    /// Nested helper apps count only with a live process of the same
    /// bundle above them: without one the app is gone, and what is left is
    /// an orphan. Login items and other background agents draw nothing.
    init?(root: KillWorkloadProcess, ancestors: [KillWorkloadAncestor]) {
        let path = root.executablePath.lowercased()
        let bundle = ThermalWorkloadResolver.applicationPath(root.executablePath)
        if path.contains(".xpc/") {
            isXPCService = true
        } else if let bundle, path.contains("/contents/frameworks/") || path.contains("/contents/helpers/"),
                  ancestors.contains(where: { ThermalWorkloadResolver.applicationPath($0.executablePath) == bundle }) {
            isXPCService = false
        } else {
            return nil
        }
        appName = bundle.map { URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent }
        role = Self.role(of: root, lowercasedPath: path)
    }

    /// What Chromium and WebKit helpers call themselves, then the `--type`
    /// they were started with: several helpers share one executable name.
    private static func role(of process: KillWorkloadProcess, lowercasedPath path: String) -> Role {
        let executable = path.split(separator: "/").last.map(String.init) ?? ""
        let identity = "\(process.name) \(executable)".lowercased()
        if identity.contains("renderer") || identity.contains("webcontent") { return .renderer }
        if identity.contains("gpu") { return .gpu }
        if identity.contains("networking") { return .networking }
        let command = String(decoding: process.commandLine.utf8.prefix(512), as: UTF8.self).lowercased()
        if command.contains("--type=renderer") { return .renderer }
        if command.contains("--type=gpu-process") { return .gpu }
        if command.contains("--type=utility"), command.contains("network") { return .networking }
        return .other
    }

    /// A note for most helpers, a caution for the one that draws a window
    /// or tab. Hedged throughout: what an app does when a helper goes
    /// depends on the app.
    var risk: KillRisk {
        let severity: KillRiskSeverity = role == .renderer ? .caution : .info
        guard isXPCService else {
            let app = appName ?? "The app"
            let detail = switch role {
            case .renderer: "\(app) stays open, but the window or tab this process draws may go blank or need a reload."
            case .gpu: "\(app) stays open, but its windows may flicker while it starts its graphics process again."
            case .networking: "\(app) stays open, but its network requests may fail until it starts its network service again."
            case .other: "\(app) stays open, but the feature this process provides may stop working for a moment."
            }
            return KillRisk(kind: .appHelper, severity: severity, title: "Part of \(app)", detail: detail)
        }
        // The service does not say which app uses it, unless it lives in one.
        let who = appName ?? "An app"
        let it = appName ?? "that app"
        let detail = switch role {
        case .renderer:
            "\(who) started this service for one of its windows or tabs. If \(it) is open, that window or tab may go blank or need a reload."
        case .gpu:
            "\(who) uses this service to draw. If \(it) is open, its windows may flicker while the service starts again."
        case .networking:
            "\(who) uses this service for its network requests. If \(it) is open, they may fail until the service starts again."
        case .other:
            "\(who) uses this service. If \(it) is open, the feature that depends on it may stop working until the app starts it again."
        }
        return KillRisk(kind: .appHelper, severity: severity, title: "Service used by \(appName ?? "an app")", detail: detail)
    }
}
