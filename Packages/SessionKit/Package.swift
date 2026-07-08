// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SessionKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "SessionKit", targets: ["SessionKit"]),
    ],
    dependencies: [
        .package(path: "../ObdKit"),
    ],
    targets: [
        .target(
            name: "SessionKit",
            dependencies: ["ObdKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "SessionKitTests",
            dependencies: ["SessionKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
