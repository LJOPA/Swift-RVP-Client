// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RVPKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "RVPKit", targets: ["RVPKit"]),
        .executable(name: "rvp-probe", targets: ["rvp-probe"]),
    ],
    targets: [
        .target(name: "RVPKit"),
        .executableTarget(name: "rvp-probe", dependencies: ["RVPKit"]),
        .testTarget(name: "RVPKitTests", dependencies: ["RVPKit"]),
    ]
)
