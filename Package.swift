// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Limits",
    platforms: [.macOS(.v14)],
    products: [.executable(name: "Limits", targets: ["LimitsApp"])],
    targets: [
        .target(name: "LimitsCore"),
        .executableTarget(name: "LimitsApp", dependencies: ["LimitsCore"]),
        .testTarget(name: "LimitsCoreTests", dependencies: ["LimitsCore"])
    ],
    swiftLanguageModes: [.v5]
)
