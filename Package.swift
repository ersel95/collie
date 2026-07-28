// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Collie",
    platforms: [
        .iOS(.v17),
        .macOS(.v14) // The core (Jira client, queue, builder) is UIKit-free — it also compiles/tests on macOS.
    ],
    products: [
        // Core: screenshot → banner → form → report, uploaded over plain HTTPS.
        // The UI layer sits behind `#if canImport(UIKit)`; it compiles on every platform.
        .library(name: "Collie", targets: ["Collie"]),
        // Optional transport for hosts whose network policy allows Firebase but not
        // arbitrary destinations. Link this INSTEAD of writing your own uploader; the
        // core stays free of any Firebase dependency.
        .library(name: "CollieFirebase", targets: ["CollieFirebase"])
    ],
    dependencies: [
        // Only `CollieFirebase` links this. Apps that use the plain HTTPS transport
        // never build it.
        .package(url: "https://github.com/firebase/firebase-ios-sdk.git", from: "11.0.0")
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
        .target(
            name: "CollieFirebase",
            dependencies: [
                "Collie",
                .product(name: "FirebaseFirestore", package: "firebase-ios-sdk"),
                .product(name: "FirebaseStorage", package: "firebase-ios-sdk")
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
