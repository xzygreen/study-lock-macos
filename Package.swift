// swift-tools-version: 5.10

import PackageDescription

let package = Package(
    name: "StudyLock",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "StudyLock", targets: ["StudyLock"])
    ],
    targets: [
        .executableTarget(
            name: "StudyLock",
            path: "Sources/StudyLock"
        ),
        .testTarget(
            name: "StudyLockTests",
            dependencies: ["StudyLock"],
            path: "Tests/StudyLockTests"
        )
    ]
)
