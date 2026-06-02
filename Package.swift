// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Usage",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Usage", targets: ["Usage"])
    ],
    targets: [
        .executableTarget(
            name: "Usage",
            linkerSettings: [
                .linkedFramework("AppKit")
            ]
        )
    ]
)
