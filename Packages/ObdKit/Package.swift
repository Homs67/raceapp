// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "ObdKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "ObdKit", targets: ["ObdKit"]),
    ],
    targets: [
        .target(
            name: "ObdKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ObdKitTests",
            dependencies: ["ObdKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
