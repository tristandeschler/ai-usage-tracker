// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "UsageKit",
    platforms: [.macOS(.v26), .iOS(.v26)],
    products: [
        .library(name: "UsageKit", targets: ["UsageKit"]),
    ],
    targets: [
        .target(name: "UsageKit"),
        .testTarget(
            name: "UsageKitTests",
            dependencies: ["UsageKit"],
            resources: [.copy("Fixtures")]
        ),
    ]
)
