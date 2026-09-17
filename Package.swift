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
            dependencies: ["CallRecorderCore"],
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
