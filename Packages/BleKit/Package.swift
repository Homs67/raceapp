// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "BleKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "BleKit", targets: ["BleKit"]),
    ],
    targets: [
        .target(
            name: "BleKit",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "BleKitTests",
            dependencies: ["BleKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
