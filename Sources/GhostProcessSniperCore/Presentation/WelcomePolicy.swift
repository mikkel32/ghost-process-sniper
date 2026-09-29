import Foundation

/// When the console opens itself with the first-run welcome, and what that
/// welcome may offer. Ghost has no Dock icon and opens nothing on launch, so
/// someone who has just double-clicked it sees no sign it started.
///
/// Only a launch that finds no radar store is a newcomer's: every 2.x user
/// already has one, so an upgrade is never welcomed as if it were new.
public enum WelcomePolicy {
    /// The welcome a launch has recorded as shown. Raise it only when a later
    /// release adds a welcome that people who saw this one should see too.
    public static let currentVersion = 1

    /// Whether nothing has ever run here: the store's folder does not exist.
    /// The store creates it when it first opens, on the first refresh, so ask
    /// before the monitor starts. Making the store (the monitor does, at
    /// launch) touches no disk.
    public static func isFirstEverLaunch(
        storeURL: URL = RadarStore.defaultURL(),
        fileManager: FileManager = .default
    ) -> Bool {
        !fileManager.fileExists(atPath: storeURL.deletingLastPathComponent().path)
    }

    public static func shouldWelcome(lastSeenVersion: Int, isFirstEverLaunch: Bool, launchArguments: [String]) -> Bool {
        guard isFirstEverLaunch, lastSeenVersion < currentVersion else {
            return false
        }
        // These ask for a window (`dev.sh run` passes `--console`), so a sheet
        // over it would be unasked for.
        return !launchArguments.contains { $0 == "--console" || $0 == "--section" }
    }

    /// Whether the welcome offers "open at login". Registering a copy that
    /// runs from a disk image or from the read-only mount macOS uses for a
    /// downloaded app would leave a login item that points nowhere after the
    /// next restart, so only a copy in an Applications folder is offered it.
    public static func offersLaunchAtLogin(
        bundleURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> Bool {
        let path = bundleURL.standardizedFileURL.path
        let folders = ["/Applications", homeDirectory.standardizedFileURL.path + "/Applications"]
        // The default volume ignores case, so `/applications/…` is the same folder.
        return folders.contains { path.range(of: $0 + "/", options: [.anchored, .caseInsensitive]) != nil }
    }
}
