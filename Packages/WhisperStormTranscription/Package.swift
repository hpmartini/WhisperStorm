// swift-tools-version:5.9
import PackageDescription

// The transcription core of WhisperStorm (16 kHz mono PCM in, text out), shared by the macOS app and iOS clients.
// Audio capture stays in each app: macOS uses CoreAudio device selection, iOS uses AVAudioSession.
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
            dependencies: [.product(name: "WhisperKit", package: "argmax-oss-swift")]
        ),
        .testTarget(
            name: "WhisperStormTranscriptionTests",
            dependencies: ["WhisperStormTranscription"]
        ),
    ]
)
