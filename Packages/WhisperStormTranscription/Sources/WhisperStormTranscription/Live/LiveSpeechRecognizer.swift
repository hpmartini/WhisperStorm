import AVFoundation
import Foundation
import Speech

/// Apple's on-device SpeechTranscriber for live text; Whisper stays the final quality.
/// `feed` takes the same 16 kHz mono samples as `SpeechChunker`, so result times share the chunk clock.
@available(macOS 26, iOS 26, *)
public final class LiveSpeechRecognizer {
    public typealias Handler = (_ isFinal: Bool, _ words: [LiveWord], _ through: TimeInterval) -> Void

    private static let inputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: SpeechChunker.sampleRate,
                                                   channels: 1, interleaved: false)!

    private struct Failure: LocalizedError {
        let errorDescription: String?
    }

    static func transcriber(_ locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(locale: locale, transcriptionOptions: [],
                          reportingOptions: [.volatileResults, .fastResults], attributeOptions: [.audioTimeRange])
    }

    /// Installs the model once (free, on-device, no extra permission).
    public static func prepare(locale: Locale, diagnostics: @escaping (String) -> Void) async -> Locale? {
        guard let supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale) else {
            diagnostics("LIVE unavailable: \(locale.identifier) not supported")
            return nil
        }
        do {
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber(supported)]) {
                diagnostics("LIVE downloading \(supported.identifier) model")
                try await request.downloadAndInstall()
            }
            diagnostics("LIVE ready (\(supported.identifier))")
            return supported
        } catch {
            diagnostics("LIVE unavailable: \(error.localizedDescription)")
            return nil
        }
    }

    private let analyzer: SpeechAnalyzer
    private let sink: AsyncStream<AnalyzerInput>.Continuation
    private let converter: AVAudioConverter
    private let format: AVAudioFormat
    private let reader: Task<Void, Never>
    private var fedAny = false  // feed context only

    public static func start(locale: Locale, handler: @escaping Handler) async throws -> LiveSpeechRecognizer {
        let transcriber = transcriber(locale)
        let analyzer = SpeechAnalyzer(modules: [transcriber], options: .init(priority: .userInitiated, modelRetention: .lingering))
        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber]),
              let converter = AVAudioConverter(from: inputFormat, to: format)
        else { throw Failure(errorDescription: "no audio format for SpeechTranscriber") }
        try await analyzer.prepareToAnalyze(in: format)
        let (stream, sink) = AsyncStream<AnalyzerInput>.makeStream()
        try await analyzer.start(inputSequence: stream)
        let reader = Task {
            do {
                for try await result in transcriber.results {
                    handler(result.isFinal, Self.words(result.text), result.range.end.seconds)
                }
            } catch {
                Log.transcription.error("LIVE results ended: \(error.localizedDescription, privacy: .public)")
            }
        }
        return LiveSpeechRecognizer(analyzer: analyzer, sink: sink, converter: converter, format: format, reader: reader)
    }

    private init(analyzer: SpeechAnalyzer, sink: AsyncStream<AnalyzerInput>.Continuation, converter: AVAudioConverter,
                 format: AVAudioFormat, reader: Task<Void, Never>) {
        (self.analyzer, self.sink, self.converter, self.format, self.reader) = (analyzer, sink, converter, format, reader)
    }

    /// The first buffer carries `offset`, so a recognizer started late keeps the chunk clock.
    public func feed(_ samples: [Float], at offset: Int) {
        guard !samples.isEmpty,
              let input = AVAudioPCMBuffer(pcmFormat: Self.inputFormat, frameCapacity: AVAudioFrameCount(samples.count))
        else { return }
        input.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { input.floatChannelData![0].update(from: $0.baseAddress!, count: samples.count) }
        let capacity = AVAudioFrameCount(Double(samples.count) * format.sampleRate / SpeechChunker.sampleRate) + 64
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return }
        var fed = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, out.frameLength > 0 else { return }
        let startTime = fedAny ? nil : CMTime(value: CMTimeValue(offset), timescale: CMTimeScale(SpeechChunker.sampleRate))
        sink.yield(AnalyzerInput(buffer: out, bufferStartTime: startTime))
        fedAny = true
    }

    public func finish() async {
        sink.finish()
        do {
            try await analyzer.finalizeAndFinishThroughEndOfInput()
        } catch {
            Log.transcription.error("LIVE finish: \(error.localizedDescription, privacy: .public)")
        }
        await reader.value
    }

    public func cancel() async {
        sink.finish()
        reader.cancel()
        await analyzer.cancelAndFinishNow()
        await reader.value
    }

    /// A run not starting with a blank ("fters" after "Ö", a comma) belongs to the previous word,
    /// so a Whisper cut never splits a word.
    static func words(_ text: AttributedString) -> [LiveWord] {
        var out: [LiveWord] = []
        for run in text.runs {
            let piece = String(text[run.range].characters)
            let range = run.audioTimeRange
            if let last = out.last, !(piece.first?.isWhitespace ?? false) || range == nil {
                out[out.count - 1] = LiveWord(start: last.start, end: max(last.end, range?.end.seconds ?? last.end), text: last.text + piece)
            } else if let range {
                out.append(LiveWord(start: range.start.seconds, end: range.end.seconds, text: piece))
            }
        }
        return out
    }
}
