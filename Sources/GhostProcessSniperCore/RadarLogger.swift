import Foundation
import OSLog

public enum RadarLogger {
    public static let subsystem = "com.local.GhostProcessSniper"

    public static let sampler = Logger(subsystem: subsystem, category: "sampler")
    public static let scoring = Logger(subsystem: subsystem, category: "scoring")
    public static let store = Logger(subsystem: subsystem, category: "store")
    public static let rules = Logger(subsystem: subsystem, category: "rules")
    public static let notifications = Logger(subsystem: subsystem, category: "notifications")
    public static let kill = Logger(subsystem: subsystem, category: "kill")
    public static let ui = Logger(subsystem: subsystem, category: "ui")
    public static let performance = Logger(subsystem: subsystem, category: "performance")
    public static let signposter = OSSignposter(subsystem: subsystem, category: "performance")
}
