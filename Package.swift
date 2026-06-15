// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrackHubSDK",
    platforms: [
        .iOS(.v14),
        .macOS(.v12), // core logic is platform-independent; tests run on macOS
    ],
    products: [
        .library(name: "TrackHub", targets: ["TrackHub"]),
    ],
    targets: [
        .target(
            name: "TrackHub",
            path: "Sources/TrackHub",
            // ship the privacy manifest so embedding apps inherit no undeclared
            // data-use / required-reason-API obligations
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        // Plain executable test runner: works with bare Command Line Tools
        // (no XCTest/Testing modules required). Run: swift run encoder-tests
        .executableTarget(
            name: "encoder-tests",
            dependencies: ["TrackHub"],
            path: "Sources/EncoderTests"
        ),
        // E2E smoke against a real deployment (install report + schema fetch
        // + conversion encoding): swift run live-check <endpoint> <token>
        .executableTarget(
            name: "live-check",
            dependencies: ["TrackHub"],
            path: "Sources/LiveCheck"
        ),
    ]
)
