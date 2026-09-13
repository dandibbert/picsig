// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "PicSigCore",
    platforms: [.iOS(.v17), .macOS(.v13)],
    products: [.library(name: "PicSigCore", targets: ["PicSigCore"])],
    targets: [
        .target(name: "PicSigCore"),
        .testTarget(name: "PicSigCoreTests", dependencies: ["PicSigCore"])
    ]
)
