// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "WorktreeCleaner",
    platforms: [
        .macOS(.v14)
    ],
    products: [
        .executable(name: "WorktreeCleaner", targets: ["WorktreeCleaner"])
    ],
    targets: [
        .executableTarget(
            name: "WorktreeCleaner",
            path: "Sources/WorktreeCleaner"
        ),
        .testTarget(
            name: "WorktreeCleanerTests",
            dependencies: ["WorktreeCleaner"],
            path: "Tests/WorktreeCleanerTests"
        )
    ]
)
