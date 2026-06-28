// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Ouroboros",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "Ouroboros", targets: ["Ouroboros"]),
        .library(name: "OuroborosUI", targets: ["OuroborosUI"]),
    ],
    targets: [
        .target(name: "Ouroboros"),
        .target(name: "OuroborosUI", dependencies: ["Ouroboros"]),
        .testTarget(name: "OuroborosTests", dependencies: ["Ouroboros"]),
    ]
)
