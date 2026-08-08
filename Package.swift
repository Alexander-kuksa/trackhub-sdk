// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrackHubSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13), // Apphud 4.4.x minimums; tests run on macOS
    ],
    products: [
        .library(name: "TrackHub", targets: ["TrackHub"]),
    ],
    dependencies: [
        .package(url: "https://github.com/apphud/ApphudSDK", exact: "4.4.8"),
    ],
    targets: [
        .target(
            name: "TrackHub",
            dependencies: [.product(name: "ApphudSDK", package: "ApphudSDK")],
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
        .testTarget(
            name: "TrackHubTests",
            dependencies: ["TrackHub"],
            path: "Tests/TrackHubTests"
        ),
    ]
)
