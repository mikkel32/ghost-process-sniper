/// A cheap developer hint for processes the radar has not classified yet.
/// Known identities get their hint from the previous tick's classified
/// families; this list only covers newcomers. Results are memoised by the raw
/// kernel name, so a stable process table costs one dictionary lookup per
/// newcomer and no lowercasing.
struct DeveloperNameHints: Sendable {
    private static let names: Set<String> = [
        "node", "npm", "pnpm", "yarn", "bun", "vite", "deno", "python", "python3",
        "ruby", "rails", "java", "gradle", "mvn", "docker", "com.docker.backend",
        "colima", "ollama", "swift", "swift-frontend", "swift-build", "xcodebuild",
        "electron", "uvicorn", "gunicorn", "webpack", "next", "cargo", "rustc", "go",
        "air", "beam.smp", "mix", "dotnet", "php"
    ]
    private static let fragments = ["electron", "vite", "ollama", "llama", "node"]
    private static let memoLimit = 4_096

    private var memo: [String: Bool] = [:]

    mutating func isDeveloperName(_ name: String) -> Bool {
        if let known = memo[name] { return known }
        let lowered = name.lowercased()
        let hinted = Self.names.contains(lowered) || Self.fragments.contains { lowered.contains($0) }
        if memo.count >= Self.memoLimit { memo.removeAll(keepingCapacity: true) }
        memo[name] = hinted
        return hinted
    }

    mutating func prune(keeping liveNames: Set<String>) {
        memo = memo.filter { liveNames.contains($0.key) }
    }
}
