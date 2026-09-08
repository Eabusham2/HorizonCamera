// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "HorizonCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "HorizonCore", targets: ["HorizonCore"])],
    targets: [
        .target(name: "HorizonCore", path: "Core"),
        .testTarget(name: "HorizonCoreTests", dependencies: ["HorizonCore"], path: "Tests/HorizonCoreTests")
    ]
)
