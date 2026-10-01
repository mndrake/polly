// swift-tools-version: 6.1
import PackageDescription

// PollyCore is platform-independent (Foundation only) so it can be built and
// unit-tested anywhere, including Linux CI. The Polly app target uses
// ScreenCaptureKit, AVFoundation, Speech and SwiftUI and is macOS-only.

var products: [Product] = [
    .library(name: "PollyCore", targets: ["PollyCore"]),
]

var dependencies: [Package.Dependency] = []

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
// On-device speaker diarization. The NemoTextProcessing trait (text
// normalisation for FluidAudio's speech-to-text) isn't needed, so it's off.
dependencies.append(.package(url: "https://github.com/FluidInference/FluidAudio.git", exact: "0.17.5", traits: []))
products.append(.executable(name: "Polly", targets: ["Polly"]))
targets.append(
    .executableTarget(
        name: "Polly",
        dependencies: [
            "PollyCore",
            .product(name: "FluidAudio", package: "FluidAudio"),
        ],
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
    dependencies: dependencies,
    targets: targets,
    swiftLanguageModes: [.v5]
)
