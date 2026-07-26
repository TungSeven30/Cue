// swift-tools-version: 6.0
import PackageDescription

// With Command Line Tools only (no Xcode), SwiftPM does not add the search
// path for the bundled Testing.framework; point at it explicitly. Harmless
// when the path does not exist (e.g. building with a full Xcode install).
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTestingLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

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
            path: "Sources",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "WhisperDeskTests",
            dependencies: ["WhisperDesk"],
            path: "Tests",
            swiftSettings: [
                .swiftLanguageMode(.v5),
                .unsafeFlags(["-F", cltFrameworks])
            ],
            linkerSettings: [
                .unsafeFlags([
                    "-F", cltFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltFrameworks,
                    "-Xlinker", "-rpath", "-Xlinker", cltTestingLibs,
                ])
            ]
        )
    ]
)
