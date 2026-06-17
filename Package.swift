// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tvmv",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark.git", branch: "gfm")
    ],
    targets: [
        .executableTarget(
            name: "tvmv",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark")
            ],
            resources: [.copy("Resources/web")]
        ),
        .testTarget(name: "tvmvTests", dependencies: ["tvmv"])
    ]
)
