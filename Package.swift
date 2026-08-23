// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "tvmv",
    platforms: [.macOS(.v14), .iOS("26.0")],
    products: [
        .executable(name: "tvmv", targets: ["tvmv"]),
        .library(name: "TVMVCore", targets: ["TVMVCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-cmark.git", branch: "gfm")
    ],
    targets: [
        .target(
            name: "TVMVCore",
            dependencies: [
                .product(name: "cmark-gfm", package: "swift-cmark"),
                .product(name: "cmark-gfm-extensions", package: "swift-cmark")
            ],
            resources: [.copy("Resources/web")]
        ),
        .executableTarget(name: "tvmv", dependencies: ["TVMVCore"]),
        .testTarget(name: "TVMVCoreTests", dependencies: ["TVMVCore"]),
        .testTarget(name: "tvmvTests", dependencies: ["tvmv"])
    ]
)
