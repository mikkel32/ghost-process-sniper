import Foundation

/// Where a process was most likely launched from, judged by its path. On
/// macOS every GUI app, LaunchAgent and brew service is a child of launchd
/// (pid 1), so "parent is pid 1" alone never means "detached" or "forgotten".
public enum LaunchOrigin {
    /// The main executable of an .app bundle, not a helper or XPC service.
    public static func isAppMainBinary(path: String, name: String) -> Bool {
        let path = path.lowercased()
        guard path.range(of: #"\.app/contents/macos/[^/]+$"#, options: .regularExpression) != nil else { return false }
        let nested = [".app/contents/frameworks/", "/contents/helpers/", ".app/contents/library/", "/contents/xpcservices/"]
        return !nested.contains(where: path.contains) && !name.lowercased().contains("helper")
    }

    /// A system daemon, login item, privileged helper or Homebrew service that
    /// launchd starts and supervises on purpose.
    public static func isLaunchdManaged(path: String, commandLine: String = "") -> Bool {
        let path = path.lowercased()
        let systemPrefixes = ["/system/", "/usr/libexec/", "/usr/sbin/", "/library/apple/", "/library/privilegedhelpertools/"]
        let bundledServices = [".app/contents/library/loginitems/", "/contents/library/launchservices/",
                               ".app/contents/helpers/", "/library/application support/"]
        if systemPrefixes.contains(where: path.hasPrefix) || bundledServices.contains(where: path.contains) {
            return true
        }
        return isHomebrewService(path: path) || commandLine.lowercased().contains("homebrew.mxcl")
    }

    // `brew services` runs formulae from their opt links:
    // /opt/homebrew/opt/<formula>/bin/<tool> or /usr/local/opt/<formula>/bin/<tool>.
    private static func isHomebrewService(path: String) -> Bool {
        for prefix in ["/opt/homebrew/opt/", "/usr/local/opt/"] where path.hasPrefix(prefix) {
            let rest = path.dropFirst(prefix.count)
            return rest.contains("/bin/") || rest.contains("/sbin/")
        }
        return false
    }
}
