// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "ZoomScroller",
    platforms: [.iOS(.v17)],
    products: [.library(name: "ZoomScroller", targets: ["ZoomScroller"])],
    targets: [
        .target(name: "ZoomScroller", resources: [.process("Shaders")]),
        .testTarget(name: "ZoomScrollerTests", dependencies: ["ZoomScroller"])
    ]
)
