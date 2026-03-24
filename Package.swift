// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "TokenBox",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "TokenBox", targets: ["TokenBox"])
    ],
    dependencies: [
        .package(url: "https://github.com/stephencelis/SQLite.swift.git", from: "0.15.3")
    ],
    targets: [
        .executableTarget(
            name: "TokenBox",
            dependencies: [
                .product(name: "SQLite", package: "SQLite.swift")
            ],
            path: "Sources",
            resources: [
                .process("../Resources")
            ]
        ),
        .testTarget(
            name: "SplitFlapTests",
            dependencies: ["TokenBox"],
            path: "Tests/SplitFlapTests"
        ),
        .testTarget(
            name: "DataLayerTests",
            dependencies: ["TokenBox"],
            path: "Tests/DataLayerTests"
        ),
        .testTarget(
            name: "SharingTests",
            dependencies: ["TokenBox"],
            path: "Tests/SharingTests"
        )
    ]
)
