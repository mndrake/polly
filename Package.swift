// swift-tools-version: 6.0
import PackageDescription

// PollyCore is platform-independent (Foundation only) so it can be built and
// unit-tested anywhere, including Linux CI. The Polly app target uses
// ScreenCaptureKit, AVFoundation, Speech and SwiftUI and is macOS-only.

var products: [Product] = [
    .library(name: "PollyCore", targets: ["PollyCore"]),
]

var targets: [Target] = [
    .target(
        name: "PollyCore",
        path: "Sources/PollyCore"
    ),
    .testTarget(
        name: "PollyCoreTests",
        dependencies: ["PollyCore"],
        path: "Tests/PollyCoreTests"
    ),
]

#if os(macOS)
products.append(.executable(name: "Polly", targets: ["Polly"]))
targets.append(
    .executableTarget(
        name: "Polly",
        dependencies: ["PollyCore"],
        path: "Sources/Polly",
        linkerSettings: [
            // Embed Info.plist in the binary so permission prompts (microphone,
            // speech recognition) work even when launched via `swift run`.
            .unsafeFlags([
                "-Xlinker", "-sectcreate",
                "-Xlinker", "__TEXT",
                "-Xlinker", "__info_plist",
                "-Xlinker", "\(Context.packageDirectory)/App/Info.plist",
            ]),
        ]
    )
)
#endif

let package = Package(
    name: "Polly",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets,
    swiftLanguageModes: [.v5]
)
