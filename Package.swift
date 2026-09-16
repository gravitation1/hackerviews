// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "QuietHNCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "QuietHNCore", targets: ["QuietHNCore"])],
    targets: [
        .target(name: "QuietHNCore", path: "QuietHN/Core"),
        .testTarget(name: "QuietHNCoreTests", dependencies: ["QuietHNCore"], path: "Tests/CoreTests")
    ]
)
