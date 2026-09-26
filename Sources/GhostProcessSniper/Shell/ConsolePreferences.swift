import Foundation
import GhostProcessSniperCore

/// The console choices worth keeping between launches. The session itself
/// survives closing the window; these survive quitting the app.
enum ConsolePreferences {
    private static let sortKey = "GhostProcessSniper.Console.familySort"
    private static let filterKey = "GhostProcessSniper.Console.familyFilter"
    private static let inspectorKey = "GhostProcessSniper.Console.showInspector"

    static var familySort: RadarSort {
        get { UserDefaults.standard.string(forKey: sortKey).flatMap(RadarSort.init(rawValue:)) ?? .smart }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: sortKey) }
    }

    static var familyFilter: RadarFilter {
        get { UserDefaults.standard.string(forKey: filterKey).flatMap(RadarFilter.init(rawValue:)) ?? .all }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: filterKey) }
    }

    static var showInspector: Bool {
        get { UserDefaults.standard.bool(forKey: inspectorKey) }
        set { UserDefaults.standard.set(newValue, forKey: inspectorKey) }
    }
}
