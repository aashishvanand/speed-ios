// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CFSpeedKit",
    platforms: [
        .iOS(.v17),
        .tvOS(.v17),
        .macOS(.v14),
    ],
    products: [
        .library(name: "CFSpeedKit", targets: ["CFSpeedKit"])
    ],
    targets: [
        // Swift 6 language mode: full data-race checking for the engine,
        // which is where all the cross-thread work (URLSession delegate
        // callbacks, concurrent workers) lives.
        .target(name: "CFSpeedKit"),
        .testTarget(name: "CFSpeedKitTests", dependencies: ["CFSpeedKit"]),
    ],
    swiftLanguageModes: [.v6]
)
