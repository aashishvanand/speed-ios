// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "CFSpeedKit",
    platforms: [
        .iOS(.v16),
        .tvOS(.v16),
    ],
    products: [
        .library(name: "CFSpeedKit", targets: ["CFSpeedKit"])
    ],
    targets: [
        .target(name: "CFSpeedKit"),
        .testTarget(name: "CFSpeedKitTests", dependencies: ["CFSpeedKit"]),
    ]
)
