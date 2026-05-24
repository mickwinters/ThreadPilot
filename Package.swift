// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "ThreadPilot",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "ThreadPilot", targets: ["ThreadPilot"])
    ],
    targets: [
        .executableTarget(
            name: "ThreadPilot"
        )
    ]
)
