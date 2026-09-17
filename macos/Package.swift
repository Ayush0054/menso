// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "Menso",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "MensoApp", targets: ["MensoApp"]),
        .library(name: "MensoCore", targets: ["MensoCore"]),
    ],
    dependencies: [
        // Immutable commits behind the reviewed v7.10.0, 2.9.4, and 151.0.0
        // release tags. The release lane must never execute mutable tag code
        // while signing credentials are present.
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            revision: "36e30a6f1ef10e4194f6af0cff90888526f0c115"
        ),
        .package(
            url: "https://github.com/sparkle-project/Sparkle.git",
            revision: "b6496a74a087257ef5e6da1c5b29a447a60f5bd7"
        ),
        .package(
            url: "https://github.com/stasel/WebRTC.git",
            revision: "19aa8c1fc7120d50df987b7111f42d5024df3d54"
        ),
    ],
    targets: [
        .target(
            name: "MensoCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "WebRTC", package: "WebRTC"),
            ],
            path: "Sources/MensoCore"
        ),
        .testTarget(
            name: "MensoCoreTests",
            dependencies: ["MensoCore"],
            path: "Tests/MensoCoreTests"
        ),
        .executableTarget(
            name: "MensoApp",
            dependencies: [
                "MensoCore",
                .product(name: "Sparkle", package: "Sparkle"),
            ],
            path: "Sources/MensoApp",
            linkerSettings: [
                .unsafeFlags([
                    "-Xlinker", "-rpath",
                    "-Xlinker", "@executable_path/../Frameworks",
                ]),
            ]
        ),
    ]
)
