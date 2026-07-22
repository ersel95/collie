// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Collie",
    platforms: [
        .iOS(.v17),
        .macOS(.v14) // The core (Jira client, queue, builder) is UIKit-free — it also compiles/tests on macOS.
    ],
    products: [
        // Single product: screenshot → banner → form → subtask + attachments directly in Jira.
        // The UI layer sits behind `#if canImport(UIKit)`; it compiles on every platform.
        .library(name: "Collie", targets: ["Collie"])
    ],
    targets: [
        .target(
            name: "Collie",
            resources: [
                // SDK privacy manifest: contains a real data-collection declaration
                // (device id + screenshot + telemetry) — an App Store requirement.
                .copy("PrivacyInfo.xcprivacy")
            ],
            swiftSettings: [
                .enableExperimentalFeature("StrictConcurrency")
            ]
        ),
        .testTarget(
            name: "CollieTests",
            dependencies: ["Collie"],
            swiftSettings: [.enableExperimentalFeature("StrictConcurrency")]
        )
    ]
)
