// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "RVPKit",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [
        .library(name: "RVPKit", targets: ["RVPKit"]),
    ],
    targets: [
        .target(name: "RVPKit"),
        .testTarget(name: "RVPKitTests", dependencies: ["RVPKit"]),
    ]
)
