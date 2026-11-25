// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorktreeCleaner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .library(name: "WorktreeCleanerCore", targets: ["WorktreeCleanerCore"]),
        .executable(name: "WorktreeCleaner", targets: ["WorktreeCleaner"]),
        .executable(name: "WorktreeCleanerMCP", targets: ["WorktreeCleanerMCP"])
    ],
    targets: [
        .target(
            name: "WorktreeCleanerCore",
            path: "Sources/WorktreeCleanerCore"
        ),
        .executableTarget(
            name: "WorktreeCleaner",
            dependencies: ["WorktreeCleanerCore"],
            path: "Sources/WorktreeCleaner"
        ),
        .executableTarget(
            name: "WorktreeCleanerMCP",
            dependencies: ["WorktreeCleanerCore"],
            path: "Sources/WorktreeCleanerMCP"
        ),
        .testTarget(
            name: "WorktreeCleanerTests",
            dependencies: ["WorktreeCleanerCore"],
            path: "Tests/WorktreeCleanerTests"
        )
    ]
)
