import Foundation

public struct CulpritAnalysis: Equatable, Sendable {
    public let kind: DevProcessKind
    public let likelyCause: String
    public let nextAction: String
    public let repoHint: String?
    public let evidence: [String]

    public init(
        family: ProcessFamily,
        classifier: DevProcessClassifier = DevProcessClassifier(),
        classification providedClassification: DevClassification? = nil
    ) {
        let classification = providedClassification ?? family.classification ?? classifier.classification(for: family)
        kind = classification.kind
        repoHint = Self.repoHint(for: family)
        let hasCredibleForecast = family.forecastIsCredibleEarlyWarning
        let hasCredibleEscalation = family.forecastIsCredibleEscalation
        let forecastActionDetail = family.presentedForecastRecommendation.detail

        var evidence = [classification.reason]
        for signal in family.hardwareSignals.prefix(3) {
            evidence.append(signal.reason)
        }
        let growth = family.trend.credibleMemoryVelocity
        if growth > 0 {
            evidence.append("Memory rising \(Int(growth.rounded())) MB/min")
        }
        if family.totalCPUPercent >= 50 {
            evidence.append("CPU burst \(Int(family.totalCPUPercent.rounded()))%")
        }
        if family.childCount >= 4 {
            evidence.append("\(family.childCount) children in tree")
        }
        if hasCredibleForecast {
            evidence.append("\(family.forecastPresentationText), ETA \(family.forecast.etaText)")
            evidence.append(family.forecast.whyNow)
        } else if family.forecast.state >= .warming {
            evidence.append("Forecast is still collecting evidence")
        }
        if let cwd = family.forensics.currentDirectory {
            evidence.append("cwd \(cwd)")
        }
        self.evidence = Array(evidence.prefix(5))

        switch classification.kind {
        case .nodeServer:
            likelyCause = hasCredibleEscalation ? "Node dev server is trending toward a leak" : (growth > 0 ? "Node dev server or watcher memory growth" : "Node or JavaScript dev server consuming resources")
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect command, then Kill Tree if this server is stale." : "Inspect tree and stop the owning terminal/app.")
        case .electronApp:
            likelyCause = hasCredibleForecast ? "Electron helper tree is heating up before a hard threshold" : (family.childCount >= 4 ? "Electron renderer/helper fanout" : "Electron app helper using memory")
            nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect renderer tree and close or restart the owning app."
        case .pythonService:
            likelyCause = "Python service, notebook, or worker process is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (growth > 0 ? "Inspect cwd and restart the service before it crosses the threshold." : "Inspect command and stop it from its terminal if expected.")
        case .dockerHelper:
            likelyCause = "Container or VM helper is backing a dev workload"
            nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect ports and project path, then stop the compose/VM workload if stale."
        case .localModelRunner:
            likelyCause = "Local model runner has a large resident footprint"
            nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect model command and unload or restart the runner when idle."
        case .javaServer:
            likelyCause = "JVM build or server process is holding memory"
            nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect command and restart the Gradle/Maven/server process if stale."
        case .rubyServer:
            likelyCause = "Ruby/Rails service is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect cwd and stop the server if the project is no longer in use."
        case .swiftBuild:
            likelyCause = "Swift build toolchain work is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : "Let active builds finish; kill only stale compiler trees."
        case .goService:
            likelyCause = "Go compiler or backend service is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect ports and Kill Tree if the backend service is stale." : "Inspect running Go binary or live-reloading watcher.")
        case .rustService:
            likelyCause = "Rust build target or active server process is running"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect command and Kill Tree if target binary is orphaned." : "Let Cargo compilation complete or restart active server.")
        case .bunServer:
            likelyCause = "Bun server runtime is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect command, then Kill Tree if the Bun server is stale." : "Inspect process tree and stop the server.")
        case .denoServer:
            likelyCause = "Deno secure JavaScript runtime is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect command, then Kill Tree if Deno server is stale." : "Inspect process and stop it via terminal.")
        case .phpService:
            likelyCause = "PHP service, Laravel server, or composer background task is running"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect cwd and Kill Tree if PHP/Artisan command is orphaned." : "Stop the artisan server or PHP-FPM process manually.")
        case .elixirService:
            likelyCause = "Elixir/Phoenix backend service or mix build is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect and Kill Tree if Phoenix server is orphaned." : "Stop the mix server or IEx session.")
        case .dotnetService:
            likelyCause = ".NET service, dotnet watch reloader, or build target is active"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect command, then Kill Tree if dotnet reloader is stale." : "Terminate the active dotnet session or reload server.")
        case .cliTool:
            likelyCause = "Developer CLI process is still running in the background"
            nextAction = hasCredibleForecast ? forecastActionDetail : (family.isKillable ? "Inspect and Kill Tree if this command is stale." : "Inspect owner before taking action.")
        case .unknownHeavy:
            if let signal = family.hardwareSignals.first {
                likelyCause = "Unclassified process is creating \(signal.kind.label.lowercased())"
                nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect owner, path, and open resources before deciding whether to kill."
            } else {
                likelyCause = "Unknown heavy process crossed radar heuristics"
                nextAction = hasCredibleForecast ? forecastActionDetail : "Inspect path, ports, and owner before deciding whether to kill."
            }
        }
    }

    private static func repoHint(for family: ProcessFamily) -> String? {
        if let cwd = family.forensics.currentDirectory, !cwd.isEmpty {
            return cwd
        }
        let command = family.root.commandLine
        for marker in ["package.json", "Package.swift", "manage.py", "Cargo.toml", "pom.xml", "build.gradle"] where command.contains(marker) {
            return marker
        }
        let path = family.root.executablePath
        guard !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
}
