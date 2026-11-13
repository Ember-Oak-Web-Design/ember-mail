// swift-tools-version:5.10
// NOTE: SwiftPM is currently broken in the installed Command Line Tools, so the canonical
// build is ./scripts/build-app.sh (swiftc directly). This manifest is kept for when a working
// toolchain/Xcode is available: `swift build` will then work too.
import PackageDescription

let package = Package(
    name: "EmberMail",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "EmberMail",
            path: "Sources/EmberMail"
        ),
    ]
)
