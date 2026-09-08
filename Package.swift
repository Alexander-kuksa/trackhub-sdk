// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "TrackHubSDK",
    platforms: [
        .iOS(.v15),
        .macOS(.v13), // parity tests run on macOS
    ],
    products: [
        .library(name: "TrackHub", targets: ["TrackHub"]),
        // Optional Google ODM bridge. Applications that select this product
        // get the official GoogleAdsOnDeviceConversion runtime without making
        // the provider-neutral TrackHub core import it directly.
        .library(name: "TrackHubGoogleODM", targets: ["TrackHubGoogleODM"]),
    ],
    dependencies: [
        // Match Google's AAP plugin compatibility range (and Adjust's public
        // ODM plugin range). SwiftPM will resolve the version together with
        // any Firebase/Google constraints owned by the host application.
        .package(
            url: "https://github.com/googleads/google-ads-on-device-conversion-ios-sdk.git",
            "2.0.0" ..< "4.0.0"
        ),
    ],
    targets: [
        .target(
            name: "TrackHub",
            dependencies: [],
            path: "Sources/TrackHub",
            // ship the privacy manifest so embedding apps inherit no undeclared
            // data-use / required-reason-API obligations
            resources: [.copy("PrivacyInfo.xcprivacy")]
        ),
        .target(
            name: "TrackHubGoogleODM",
            dependencies: [
                "TrackHub",
                .product(
                    name: "GoogleAdsOnDeviceConversion",
                    package: "google-ads-on-device-conversion-ios-sdk",
                    condition: .when(platforms: [.iOS])
                ),
            ],
            path: "Sources/TrackHubGoogleODM"
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
            dependencies: ["TrackHub", "TrackHubGoogleODM"],
            path: "Tests/TrackHubTests"
        ),
    ]
)
