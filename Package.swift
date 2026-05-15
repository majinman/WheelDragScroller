// swift-tools-version: 5.7

import PackageDescription

let package = Package(
    name: "WheelDragScroller",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "WheelDragScroller", targets: ["WheelDragScroller"])
    ],
    targets: [
        .executableTarget(
            name: "WheelDragScroller",
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("ApplicationServices"),
                .linkedFramework("CoreGraphics")
            ]
        )
    ]
)
