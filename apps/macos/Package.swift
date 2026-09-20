// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "FlowStateMac",
    defaultLocalization: "en",
    platforms: [
        .macOS("26.2")
    ],
    products: [
        .library(name: "FlowStateCore", targets: ["FlowStateCore"]),
        .executable(name: "FlowStateApp", targets: ["FlowStateApp"])
    ],
    dependencies: [
        .package(url: "https://github.com/clerk/clerk-convex-swift", exact: "0.1.0"),
        .package(url: "https://github.com/clerk/clerk-ios.git", exact: "1.5.5"),
        .package(url: "https://github.com/get-convex/convex-swift", exact: "0.8.1")
    ],
    targets: [
        .target(name: "FlowStateCore"),
        .target(name: "FlowStateCloud", dependencies: ["FlowStateCore", .product(name: "ClerkConvex", package: "clerk-convex-swift"), .product(name: "ClerkKit", package: "clerk-ios"), .product(name: "ConvexMobile", package: "convex-swift")]),
        .executableTarget(name: "FlowStateApp", dependencies: ["FlowStateCore", "FlowStateCloud"], resources: [.process("Resources")]),
        .testTarget(name: "FlowStateCoreTests", dependencies: ["FlowStateCore"]),
        .testTarget(name: "FlowStateCloudTests", dependencies: ["FlowStateCloud"]),
        .testTarget(name: "FlowStateAppTests", dependencies: ["FlowStateApp"])
    ]
)
