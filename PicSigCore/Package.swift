// swift-tools-version:5.9
import PackageDescription

// PicSigCore contains every piece of logic that does not need UIKit / Vision /
// AVFoundation: stitch planning, sensitive-data detection, masking policy,
// annotation documents and export math.
//
// The iOS app compiles the very same sources directly (see PicSig.xcodeproj),
// this package exists so that the algorithms can be built and unit tested on
// any platform, including Linux CI.
let package = Package(
    name: "PicSigCore",
    platforms: [
        .iOS(.v17),
        .macOS(.v13)
    ],
    products: [
        .library(name: "PicSigCore", targets: ["PicSigCore"])
    ],
    targets: [
        .target(name: "PicSigCore"),
        .testTarget(name: "PicSigCoreTests", dependencies: ["PicSigCore"])
    ]
)
