// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ExamPilot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ExamPilotCore", targets: ["ExamPilotCore"]),
        .executable(name: "exampilot", targets: ["ExamPilotCLI"]),
    ],
    targets: [
        .target(
            name: "ExamPilotCore",
            linkerSettings: [
                .linkedLibrary("sqlite3"),
            ]
        ),
        .executableTarget(name: "ExamPilotCLI", dependencies: ["ExamPilotCore"]),
        .testTarget(name: "ExamPilotCoreTests", dependencies: ["ExamPilotCore"]),
    ]
)
