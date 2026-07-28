// swift-tools-version: 6.0
import PackageDescription

// Ouroboros Zero — the global control plane. One core (ZeroCore), three faces:
// the daemon (ourod), the CLI (ouro), and the menu-bar app (ouroboros-zero).
// The engine (issue files, worktrees, seed prompts, terminal launching) is the
// existing Ouroboros package next door — Zero never reimplements it.

let package = Package(
    name: "OuroborosZero",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "ZeroCore", targets: ["ZeroCore"]),
        .executable(name: "ourod", targets: ["Ourod"]),
        .executable(name: "ouro", targets: ["OuroCLI"]),
        .executable(name: "ouroboros-zero", targets: ["ZeroApp"]),
    ],
    dependencies: [
        .package(path: "../swift"),
    ],
    targets: [
        .target(
            name: "ZeroCore",
            dependencies: [.product(name: "Ouroboros", package: "swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "Ourod",
            dependencies: ["ZeroCore", .product(name: "Ouroboros", package: "swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "OuroCLI",
            dependencies: ["ZeroCore", .product(name: "Ouroboros", package: "swift")],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .executableTarget(
            name: "ZeroApp",
            dependencies: [
                "ZeroCore",
                .product(name: "Ouroboros", package: "swift"),
                .product(name: "OuroborosUI", package: "swift"),
            ],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "ZeroCoreTests",
            dependencies: ["ZeroCore"],
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
