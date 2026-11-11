// swift-tools-version: 5.9
import PackageDescription
let package = Package(
    name: "Stillframe", platforms: [.macOS("15.0")],
    products: [.executable(name: "Stillframe", targets: ["Stillframe"])],
    targets: [
        .executableTarget(name: "Stillframe", linkerSettings: [
            .linkedFramework("AppKit"), .linkedFramework("SwiftUI"),
            .linkedFramework("ScreenCaptureKit"), .linkedFramework("Vision"),
            .linkedFramework("AVKit"), .linkedFramework("Carbon")
        ]),
        .testTarget(name: "StillframeTests", dependencies: ["Stillframe"])
    ]
)
