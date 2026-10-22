// swift-tools-version:5.9
// The fusion/detection core as a package, so its tests run with `swift test`
// on a Mac -- no simulator needed. The iOS app compiles the same sources.
import PackageDescription

let package = Package(
    name: "DarkWakeCore",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [.library(name: "DarkWakeCore", targets: ["DarkWakeCore"])],
    targets: [
        .target(name: "DarkWakeCore", path: "DarkWake/Core"),
        .testTarget(name: "DarkWakeCoreTests", dependencies: ["DarkWakeCore"], path: "Tests/DarkWakeCoreTests"),
    ]
)
