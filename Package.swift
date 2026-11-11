// swift-tools-version:5.9
import PackageDescription

// Entry point for remote consumers (e.g. the iOS dictation client): SwiftPM only resolves a manifest at the
// repository root. It points at the same sources as Packages/WhisperStormTranscription, which the macOS app
// uses as a local package. Keep both manifests' dependencies in sync.
let package = Package(
    name: "WhisperStormTranscription",
    platforms: [.macOS(.v14), .iOS(.v17)],
    products: [
        .library(name: "WhisperStormTranscription", targets: ["WhisperStormTranscription"]),
    ],
    dependencies: [
        .package(url: "https://github.com/argmaxinc/argmax-oss-swift", from: "1.0.0"),
    ],
    targets: [
        .target(
            name: "WhisperStormTranscription",
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")],
            path: "Packages/WhisperStormTranscription/Sources/WhisperStormTranscription"
        ),
    ]
)
