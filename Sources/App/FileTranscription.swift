import AVFoundation
import Foundation

/// One decoded control-socket request line. Pure, so the protocol can be unit-tested without a socket.
enum ControlRequest: Equatable {
    case start, stop, status
    case transcribe(path: String)
    /// The reply's "error" text.
    case invalid(String)

    static func parse(line: String) -> ControlRequest {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let cmd = obj["cmd"] as? String else { return .invalid("invalid request") }
        switch cmd {
        case "status": return .status
        case "start": return .start
        case "stop": return .stop
        case "transcribe":
            guard let path = obj["path"] as? String else { return .invalid("missing path") }
            return .transcribe(path: path)
        default: return .invalid("unknown cmd")
        }
    }
}

/// Transcribes an audio file through the given provider. Never touches the microphone or DictationCoordinator state.
struct FileTranscriber {
    /// Resolved lazily so the model is only loaded when a request passes validation and decoding.
    let provider: () async throws -> any TranscriptionProvider
    let languageCode: String?
    /// Only files inside this directory are read; otherwise any same-user process could borrow WhisperStorm's TCC grants through the socket.
    let inbox: URL

    static let defaultInbox = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/WhisperStorm/inbox", isDirectory: true)

    static let maxFileBytes: Int64 = 256 * 1024 * 1024
    /// 10 min is the producer's limit; 15 min leaves headroom (16 kHz Float32 = ~58 MB).
    static let maxDuration: TimeInterval = 15 * 60

    struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    func run(path: String) async -> [String: Any] {
        do {
            let url = try Self.validate(path: path, inbox: inbox)
            let samples = try Self.decode(url)
            let provider = try await provider()
            try await provider.prepare()
            let text = try await provider.transcribe(TranscriptionRequest(samples: samples, languageCode: languageCode))
            return ["ok": true, "phase": "success", "text": text]
        } catch {
            return ["ok": false, "phase": "error", "error": error.localizedDescription]
        }
    }

    static func validate(path: String, inbox: URL) throws -> URL {
        guard path.hasPrefix("/") else { throw Failure("path must be absolute") }
        let url = URL(fileURLWithPath: path).resolvingSymlinksInPath()
        // Resolve only the inbox's parent: if the inbox itself is a symlink (a same-user process can swap it), the file must not count as inside.
        let inboxType = (try? FileManager.default.attributesOfItem(atPath: inbox.path)[.type]) as? FileAttributeType
        let realInbox = inbox.deletingLastPathComponent().resolvingSymlinksInPath().appendingPathComponent(inbox.lastPathComponent)
        guard inboxType == .typeDirectory, url.path.hasPrefix(realInbox.path + "/") else { throw Failure("path outside inbox") }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]) else {
            throw Failure("file not found")
        }
        guard values.isRegularFile == true else { throw Failure("not a regular file") }
        let size = Int64(values.fileSize ?? 0)
        guard size > 0 else { throw Failure("file is empty") }
        guard size <= maxFileBytes else { throw Failure("file too large") }
        return url
    }

    /// Anything AVFoundation reads (m4a/mp4 AAC, wav, caf, mp3) -> 16 kHz mono Float32.
    static func decode(_ url: URL) throws -> [Float] {
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: url, commonFormat: .pcmFormatFloat32, interleaved: false) }
        catch { throw Failure("unsupported or unreadable audio file") }
        let inFormat = file.processingFormat
        guard inFormat.sampleRate > 0, file.length > 0 else { throw Failure("no audio in file") }
        guard Double(file.length) / inFormat.sampleRate <= maxDuration else { throw Failure("audio too long") }
        guard let outFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: AudioCaptureEngine.targetSampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: inFormat, to: outFormat),
              let inBuffer = AVAudioPCMBuffer(pcmFormat: inFormat, frameCapacity: 65536) else {
            throw Failure("cannot decode audio file")
        }
        let outCapacity = AVAudioFrameCount(65536 * outFormat.sampleRate / inFormat.sampleRate) + 1024
        guard let outBuffer = AVAudioPCMBuffer(pcmFormat: outFormat, frameCapacity: outCapacity) else {
            throw Failure("cannot decode audio file")
        }
        var samples: [Float] = []
        var readError: Error?
        while true {
            outBuffer.frameLength = 0
            var convError: NSError?
            let status = converter.convert(to: outBuffer, error: &convError) { _, inputStatus in
                // read() throws at EOF on some formats, so check the position first.
                if file.framePosition < file.length {
                    do { try file.read(into: inBuffer, frameCount: 65536) } catch { readError = error; inBuffer.frameLength = 0 }
                } else {
                    inBuffer.frameLength = 0
                }
                if inBuffer.frameLength == 0 { inputStatus.pointee = .endOfStream; return nil }
                inputStatus.pointee = .haveData
                return inBuffer
            }
            if status == .error || readError != nil { throw Failure("audio decoding failed") }
            if let ch = outBuffer.floatChannelData?[0], outBuffer.frameLength > 0 {
                samples.append(contentsOf: UnsafeBufferPointer(start: ch, count: Int(outBuffer.frameLength)))
            }
            if status == .endOfStream { break }
        }
        guard !samples.isEmpty else { throw Failure("no audio in file") }
        return samples
    }
}
