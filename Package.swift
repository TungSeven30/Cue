// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "WhisperDesk",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WhisperDesk", targets: ["WhisperDesk"])
    ],
    targets: [
        .executableTarget(
            name: "WhisperDesk",
            path: "Sources"
        )
    ]
)
