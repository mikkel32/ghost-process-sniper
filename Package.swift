// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "GhostProcessSniper",
    platforms: [
        .macOS("26.0")
    ],
    products: [
        .executable(name: "GhostProcessSniper", targets: ["GhostProcessSniper"]),
        .executable(name: "GhostProcessSniperCoreChecks", targets: ["GhostProcessSniperCoreChecks"]),
        .library(name: "GhostProcessSniperCore", targets: ["GhostProcessSniperCore"])
    ],
    dependencies: [
        .package(path: "Packages/ThinkingOrbsKit")
    ],
    targets: [
        .target(
            name: "GhostProcessSniperCore",
            linkerSettings: [
                .linkedFramework("IOKit"),
                .linkedLibrary("sqlite3")
            ]
        ),
        .executableTarget(
            name: "GhostProcessSniper",
            dependencies: [
                "GhostProcessSniperCore",
                .product(name: "ThinkingOrbsKit", package: "ThinkingOrbsKit")
            ]
        ),
        .executableTarget(
            name: "GhostProcessSniperCoreChecks",
            dependencies: ["GhostProcessSniperCore"],
            path: "Checks/GhostProcessSniperCoreChecks"
        ),
        .testTarget(
            name: "GhostProcessSniperCoreTests",
            dependencies: ["GhostProcessSniperCore"]
        )
    ],
    swiftLanguageModes: [.v6]
)
