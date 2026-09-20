// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlowStateMac",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "FlowStateCore", targets: ["FlowStateCore"]),
        .executable(name: "FlowStateApp", targets: ["FlowStateApp"])
    ],
    targets: [
        .target(name: "FlowStateCore"),
        .executableTarget(name: "FlowStateApp", dependencies: ["FlowStateCore"]),
        .testTarget(name: "FlowStateCoreTests", dependencies: ["FlowStateCore"])
    ]
)
