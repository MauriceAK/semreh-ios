// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "SemrehRemoteBrowser",
    platforms: [
        .iOS(.v17),
        .macOS(.v13),
    ],
    products: [
        .library(name: "SemrehRemoteBrowserCore", targets: ["SemrehRemoteBrowserCore"]),
        .library(name: "SemrehRemoteBrowserUI", targets: ["SemrehRemoteBrowserUI"]),
    ],
    targets: [
        .target(
            name: "SemrehRemoteBrowserCore",
            path: "Sources/SemrehRemoteBrowserCore"
        ),
        .target(
            name: "SemrehRemoteBrowserUI",
            dependencies: ["SemrehRemoteBrowserCore"],
            path: "Sources/SemrehRemoteBrowserUI"
        ),
        .testTarget(
            name: "SemrehRemoteBrowserCoreTests",
            dependencies: ["SemrehRemoteBrowserCore"],
            path: "Tests/SemrehRemoteBrowserCoreTests"
        ),
        .testTarget(
            name: "SemrehRemoteBrowserUITests",
            dependencies: ["SemrehRemoteBrowserCore", "SemrehRemoteBrowserUI"],
            path: "Tests/SemrehRemoteBrowserUITests"
        ),
    ]
)
