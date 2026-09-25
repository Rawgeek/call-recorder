// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "CallRecorder",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CallRecorderCore", targets: ["CallRecorderCore"]),
        .executable(name: "CallRecorder", targets: ["CallRecorderApp"]),
    ],
    // One dependency, and the transcription engine is not one of them: the model this app reads
    // with is published for MLX, which the app runs in the Python environment beside its models.
    // A speech framework linked into the app was measured against it on the same seventy-minute
    // call and answered fewer words in a quarter of the time, and the words matter more.
    dependencies: [
        .package(url: "https://github.com/tursodatabase/libsql-swift", from: "0.1.1"),
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
            ],
            resources: [.copy("diarize.py"), .copy("qwen_asr.py")]
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
