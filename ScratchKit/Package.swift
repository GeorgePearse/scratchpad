// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ScratchKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ScratchKit", targets: ["ScratchKit"]),
    ],
    targets: [
        .target(name: "ScratchKit"),
        .executableTarget(name: "padmodel", dependencies: ["ScratchKit"]),
        .testTarget(name: "ScratchKitTests", dependencies: ["ScratchKit"]),
    ]
)
