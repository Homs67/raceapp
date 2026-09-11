// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "RaceBoxKit",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "RaceBoxKit", targets: ["RaceBoxKit"]),
    ],
    dependencies: [
        .package(path: "../BleKit"),
    ],
    targets: [
        .target(
            name: "RaceBoxKit",
            dependencies: ["BleKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "RaceBoxKitTests",
            dependencies: ["RaceBoxKit"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
