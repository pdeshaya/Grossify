// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "GrossifyDesktop",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "GrossifyDesktop", targets: ["GrossifyDesktop"])
    ],
    targets: [
        .executableTarget(name: "GrossifyDesktop")
    ]
)
