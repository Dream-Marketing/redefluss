// swift-tools-version: 5.10
import PackageDescription

let package = Package(
    name: "Redefluss",
    defaultLocalization: "de",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Redefluss", targets: ["Redefluss"]),
    ],
    targets: [
        // whisper.cpp als vorkompiliertes XCFramework (Metal + Core ML), geholt von scripts/fetch-whisper.sh.
        .binaryTarget(name: "whisper", path: "Vendor/whisper.xcframework"),
        .target(
            name: "RedeflussKit",
            dependencies: ["whisper"],
            path: "Sources/RedeflussKit"
        ),
        .executableTarget(
            name: "Redefluss",
            dependencies: ["RedeflussKit"],
            path: "Sources/Redefluss",
            linkerSettings: [
                .unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"]),
            ]
        ),
        .testTarget(
            name: "RedeflussKitTests",
            dependencies: ["RedeflussKit"],
            path: "Tests/RedeflussKitTests"
        ),
    ]
)
