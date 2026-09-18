// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HackerViewsCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "HackerViewsCore", targets: ["HackerViewsCore"])],
    targets: [
        .target(name: "HackerViewsCore", path: "HackerViews/Core"),
        .testTarget(name: "HackerViewsCoreTests", dependencies: ["HackerViewsCore"], path: "Tests/CoreTests")
    ]
)
