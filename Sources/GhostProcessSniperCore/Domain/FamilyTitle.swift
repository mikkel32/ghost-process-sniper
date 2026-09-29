import Foundation

/// The name a family is shown by in lists, stop previews and notifications.
enum FamilyTitle {
    private static let runtimeSuffix = ".simruntime"

    /// The root's process name, except for a simulator: `launchd_sim` tells
    /// most people nothing, while the runtime folder in its path
    /// ("iOS 18.0.simruntime") says which simulator it is. Reads the path
    /// alone, so it costs nothing per tick. The signature and the family key
    /// keep the process name: what was learned about it stays attached.
    static func name(for root: ProcessMetrics) -> String {
        guard root.name == "launchd_sim" else { return root.name }
        // The innermost runtime folder, as the disk spells it.
        for component in root.executablePath.split(separator: "/").reversed() where component.lowercased().hasSuffix(runtimeSuffix) {
            let runtime = component.dropLast(runtimeSuffix.count).trimmingCharacters(in: .whitespaces)
            return runtime.isEmpty ? root.name : "\(runtime) Simulator"
        }
        return root.name
    }
}
