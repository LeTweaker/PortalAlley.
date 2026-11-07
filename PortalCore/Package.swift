// swift-tools-version:5.9
// PortalCore: platform-independent logic for the PortalAlley app (no ARKit /
// RealityKit), so it can be unit-tested with `swift test` on any Mac.
import PackageDescription

let package = Package(
    name: "PortalCore",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "PortalCore", targets: ["PortalCore"]),
    ],
    targets: [
        .target(name: "PortalCore"),
        .testTarget(name: "PortalCoreTests", dependencies: ["PortalCore"]),
    ]
)
