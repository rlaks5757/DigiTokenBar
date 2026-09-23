// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DigiTokenBar",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "DigiTokenBar",
            path: "Sources/DigiTokenBar",
            resources: [
                .copy("../../Resources/digimon.json"),
                .copy("../../Resources/digimon_details.json"),
            ],
            linkerSettings: [.linkedLibrary("sqlite3")]
        ),
        .testTarget(
            name: "DigiTokenBarTests",
            dependencies: ["DigiTokenBar"],
            path: "Tests/DigiTokenBarTests",
            resources: [
                .copy("Fixtures/CodexFork"),
                .copy("Fixtures/CodexSubagent"),
            ]
        ),
    ]
)
