// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Scrollpage",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Scrollpage", targets: ["Scrollpage"]),
    ],
    targets: [
        .target(name: "ScrollpageCore"),
        .executableTarget(
            name: "Scrollpage",
            dependencies: ["ScrollpageCore"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("Vision"),
                .linkedFramework("CoreGraphics"),
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
            ]
        ),
        .testTarget(name: "ScrollpageCoreTests", dependencies: ["ScrollpageCore"]),
    ]
)
