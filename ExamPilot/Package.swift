// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "ExamPilot",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ComputerAgentCore", targets: ["ComputerAgentCore"]),
        .library(name: "ExamPilotCore", targets: ["ExamPilotCore"]),
        .executable(name: "exampilot", targets: ["ExamPilotCLI"]),
    ],
    targets: [
        .target(name: "ComputerAgentCore"),
        .target(name: "ExamPilotCore"),
        .executableTarget(name: "ExamPilotCLI", dependencies: ["ExamPilotCore"]),
        .testTarget(name: "ExamPilotCoreTests", dependencies: ["ExamPilotCore"]),
        .testTarget(name: "ComputerAgentCoreTests", dependencies: ["ComputerAgentCore"]),
    ]
)
