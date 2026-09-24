// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CallRecorderCore", targets: ["CallRecorderCore"]),
        .executable(name: "CallRecorder", targets: ["CallRecorderApp"]),
    ],
    dependencies: [
        .package(url: "https://github.com/tursodatabase/libsql-swift", from: "0.1.1"),
        // Parakeet TDT 0.6B v3, run on the Neural Engine by FluidAudio (Apache-2.0). The calls
        // this app records are Russian and English, and one pass of this model answers both
        // languages where whisper.cpp had to be told which one to decode.
        //
        // Every trait is off. The one on offer, NemoTextProcessing, links a third-party binary
        // framework that has to be downloaded while the app is built, and the app reads no numbers
        // back out of a transcript itself. FluidAudio guards that engine with canImport, so an empty
        // trait set builds without it.
        .package(url: "https://github.com/FluidInference/FluidAudio.git", from: "0.12.4", traits: []),
    ],
    targets: [
        .target(
            name: "CallRecorderCore",
            dependencies: [
                .product(name: "Libsql", package: "libsql-swift"),
            ]
        ),
        .executableTarget(
            name: "CallRecorderApp",
            dependencies: [
                "CallRecorderCore",
                .product(name: "FluidAudio", package: "FluidAudio"),
            ],
            resources: [.copy("diarize.py")]
        ),
        .testTarget(
            name: "CallRecorderCoreTests",
            dependencies: [
                "CallRecorderCore",
                "CallRecorderApp",
                .product(name: "Libsql", package: "libsql-swift"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
