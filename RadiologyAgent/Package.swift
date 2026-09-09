// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "RadAgent",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "RadAgent", targets: ["RadAgent"])],
    targets: [
        .target(name: "RadAgentCore"),
        .target(name: "RadAgentImaging", dependencies: ["RadAgentCore"]),
        .executableTarget(name: "RadAgent", dependencies: ["RadAgentCore", "RadAgentImaging"]),
        .testTarget(name: "RadAgentCoreTests", dependencies: ["RadAgentCore"]),
        .testTarget(name: "RadAgentImagingTests", dependencies: ["RadAgentImaging"])
    ]
)
