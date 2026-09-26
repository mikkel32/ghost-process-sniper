import AppKit
import Foundation

public enum CleanupApplications {
    public static func validBundleID(_ value: String) -> Bool {
        value.count <= 255 && value.contains(".") && !value.split(separator: ".", omittingEmptySubsequences: false).contains("") &&
        value.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0) }
    }

    public static func runningBundleIDs() async -> Set<String> {
        await MainActor.run { Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier)) }
    }
}

public actor CleanupAppScanner {
    private let home: URL
    public init(home: URL = FileManager.default.homeDirectoryForCurrentUser) { self.home = home.resolvingSymlinksInPath() }

    public func inventory() throws -> (apps: [CleanupApplication], notices: [String]) {
        var apps: [CleanupApplication] = []
        var notices: [String] = []
        for root in [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")] {
            guard FileManager.default.fileExists(atPath: root.path) else { continue }
            var failures = 0
            guard let walker = FileManager.default.enumerator(at: root,
                includingPropertiesForKeys: [.isSymbolicLinkKey, .isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { _, _ in failures += 1; return true }) else {
                notices.append("Could not read \(root.path)"); continue
            }
            var visited = 0
            for case let url as URL in walker {
                try Task.checkCancellation()
                visited += 1
                if visited > 5_000 { notices.append("Application inventory limit reached."); break }
                if url.pathExtension.lowercased() == "app" {
                    walker.skipDescendants()
                    guard url.path == url.resolvingSymlinksInPath().path,
                          let bundle = Bundle(url: url), let id = bundle.bundleIdentifier else { continue }
                    let protected = !CleanupApplications.validBundleID(id) || id.hasPrefix("com.apple.") ||
                        id == "com.local.GhostProcessSniper" || id == Bundle.main.bundleIdentifier
                    let name = bundle.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ??
                        bundle.object(forInfoDictionaryKey: "CFBundleName") as? String ?? url.deletingPathExtension().lastPathComponent
                    apps.append(.init(url: url, name: name, bundleID: id,
                        version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Unknown version",
                        isProtected: protected))
                } else if walker.level > 2 { walker.skipDescendants() }
            }
            if failures > 0 { notices.append("\(failures) application locations were unreadable.") }
        }
        return (apps.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }, notices)
    }

    public func review(_ app: CleanupApplication, uninstall: Bool) throws -> CleanupAppReview {
        guard !app.isProtected, CleanupApplications.validBundleID(app.bundleID),
              !app.bundleID.hasPrefix("com.apple."), app.bundleID != "com.local.GhostProcessSniper",
              app.bundleID != Bundle.main.bundleIdentifier,
              Bundle(url: app.url)?.bundleIdentifier == app.bundleID else {
            throw CleanupFailure("This application is protected or its identity changed.")
        }
        let id = app.bundleID
        let library = home.appendingPathComponent("Library")
        let locations = ["Caches/\(id)", "Logs/\(id)", "Preferences/\(id).plist",
            "Saved Application State/\(id).savedState", "Application Support/\(id)",
            "HTTPStorages/\(id)", "WebKit/\(id)"]
        var items: [CleanupItem] = []
        var notices = ["Only exact bundle-identifier matches are included. Shared containers, keychains, cloud data, system helpers and name-only matches are left in place."]
        if uninstall {
            let roots = [URL(fileURLWithPath: "/Applications"), home.appendingPathComponent("Applications")]
            guard let scope = roots.first(where: { CleanupFileSystem.contains(app.url, in: $0) }) else {
                throw CleanupFailure("The app is outside the supported Applications folders.")
            }
            items.append(try item(app.url, scope: scope, category: .application, bundleID: id))
        }
        for location in locations {
            let url = library.appendingPathComponent(location)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { items.append(try item(url, scope: library, category: .appData, bundleID: id)) }
            catch is CancellationError { throw CancellationError() }
            catch { notices.append("Not included: \(url.path) - \(error.localizedDescription)") }
        }
        return .init(app: app, items: items, notices: notices)
    }

    private func item(_ url: URL, scope: URL, category: CleanupCategory, bundleID: String) throws -> CleanupItem {
        try CleanupFileSystem.checkedPath(url, scope: scope)
        let identity = try CleanupFileSystem.stamp(url)
        let measurement = try CleanupFileSystem.measure(url)
        guard try CleanupFileSystem.stamp(url) == identity else { throw CleanupFailure("Contents changed during review.") }
        return CleanupItem(url: url, scope: scope, category: category, bytes: measurement.bytes,
                           stamp: identity, treeSignature: measurement.signature, bundleID: bundleID)
    }
}
