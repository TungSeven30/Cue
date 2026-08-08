// swift-tools-version: 6.0
import PackageDescription

// With Command Line Tools only (no Xcode), SwiftPM does not add the search
// path for the bundled Testing.framework; point at it explicitly. Harmless
// when the path does not exist (e.g. building with a full Xcode install).
let cltFrameworks = "/Library/Developer/CommandLineTools/Library/Developer/Frameworks"
let cltTestingLibs = "/Library/Developer/CommandLineTools/Library/Developer/usr/lib"

let package = Package(
    name: "Cue",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "Cue", targets: ["Cue"])
    ],
    dependencies: [
        // Pinned to v1.7.2 (commit 6266a9f): the newest whisper.cpp tag whose
        // Package.swift builds the C/C++/Metal sources via SwiftPM. v1.7.3+
        // replaced the manifest with a systemLibrary that requires a
        // pkg-config-installed libwhisper, which would break the
        // zero-dependency install. Pinned by revision rather than
        // `exact: "1.7.2"` because SwiftPM forbids the unsafe build flags in
        // whisper.cpp's manifest for version-based dependencies.
        .package(
            url: "https://github.com/ggml-org/whisper.cpp",
            revision: "6266a9f9e56a5b925e9892acf650f3eb1245814d" // tag v1.7.2
        ),
        // In-app updates. Ships as a prebuilt XCFramework, so it builds fine
        // on CLT-only machines.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.9.5")
    ],
    targets: [
        .executableTarget(
            name: "Cue",
            dependencies: [
                .product(name: "whisper", package: "whisper.cpp"),
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources",
            swiftSettings: [
                .swiftLanguageMode(.v6),
                // whisper.cpp v1.7.2 exposes additional public C headers next
                // to whisper.h without listing them from its umbrella header.
                // Clang's diagnostic becomes fatal under Swift 6 even though
                // the imported API is valid.
                .unsafeFlags(["-Xcc", "-Wno-incomplete-umbrella"]),
            ]
        ),
        .testTarget(
            name: "CueTests",
            dependencies: ["Cue"],
            path: "Tests",
            swiftSettings: [
                .swiftLanguageMode(.v6),
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
