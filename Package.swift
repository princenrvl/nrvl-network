// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NRVLNetwork",
    platforms: [.macOS(.v14)],
    products: [
        // Consumed by NRVLNetwork.xcodeproj.
        .library(name: "NRVLCore", targets: ["NRVLCore"]),
        .library(name: "NRVLPersistence", targets: ["NRVLPersistence"]),
        .library(name: "NRVLDiscovery", targets: ["NRVLDiscovery"]),
        .library(name: "NRVLServices", targets: ["NRVLServices"]),
        .library(name: "NRVLTelemetry", targets: ["NRVLTelemetry"]),
        .library(name: "NRVLAdapters", targets: ["NRVLAdapters"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
    ],
    targets: [
        .target(name: "NRVLCore"),
        .target(
            name: "NRVLPersistence",
            dependencies: ["NRVLCore", .product(name: "GRDB", package: "GRDB.swift")]
        ),
        .target(name: "NRVLDiscovery", dependencies: ["NRVLCore"]),
        .target(name: "NRVLTelemetry"),
        .target(name: "NRVLAdapters", dependencies: ["NRVLCore"]),
        .target(name: "NRVLServices", dependencies: ["NRVLCore", "NRVLPersistence", "NRVLDiscovery", "NRVLAdapters"]),
        .executableTarget(
            name: "NRVLNetwork",
            dependencies: ["NRVLCore", "NRVLPersistence", "NRVLDiscovery", "NRVLServices", "NRVLTelemetry", "NRVLAdapters"],
            path: "Sources/NRVLNetworkApp"
        ),
        .testTarget(name: "NRVLPersistenceTests", dependencies: ["NRVLPersistence"]),
        .testTarget(name: "NRVLDiscoveryTests", dependencies: ["NRVLDiscovery", "NRVLServices"]),
        .testTarget(name: "NRVLTelemetryTests", dependencies: ["NRVLTelemetry"]),
        .testTarget(name: "NRVLAdaptersTests", dependencies: ["NRVLAdapters"]),
    ]
)
