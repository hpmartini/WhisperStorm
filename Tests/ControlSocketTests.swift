import AVFoundation
import XCTest

private struct StubProvider: TranscriptionProvider {
    var displayName: String { "stub" }
    var result: Result<String, Error>
    var onTranscribe: (TranscriptionRequest) -> Void = { _ in }
    func transcribe(_ request: TranscriptionRequest) async throws -> String {
        onTranscribe(request)
        return try result.get()
    }
}

final class ControlSocketTests: XCTestCase {
    // MARK: existing commands: parsing unchanged

    func testExistingCommandsParse() {
        XCTAssertEqual(ControlRequest.parse(line: #"{"cmd":"start"}"#), .start)
        XCTAssertEqual(ControlRequest.parse(line: #"{"cmd":"stop"}"#), .stop)
        XCTAssertEqual(ControlRequest.parse(line: "  {\"cmd\":\"status\"}\r\n"), .status)
    }

    func testInvalidRequestsKeepTheirErrorTexts() {
        XCTAssertEqual(ControlRequest.parse(line: "nope"), .invalid("invalid request"))
        XCTAssertEqual(ControlRequest.parse(line: ""), .invalid("invalid request"))
        XCTAssertEqual(ControlRequest.parse(line: #"{"x":1}"#), .invalid("invalid request"))
        XCTAssertEqual(ControlRequest.parse(line: #"{"cmd":"bogus"}"#), .invalid("unknown cmd"))
    }

    // MARK: transcribe: parsing

    func testTranscribeParses() {
        XCTAssertEqual(ControlRequest.parse(line: #"{"cmd":"transcribe","path":"/tmp/a.m4a"}"#), .transcribe(path: "/tmp/a.m4a"))
        XCTAssertEqual(ControlRequest.parse(line: #"{"cmd":"transcribe"}"#), .invalid("missing path"))
        XCTAssertEqual(ControlRequest.parse(line: #"{"cmd":"transcribe","path":5}"#), .invalid("missing path"))
    }

    // MARK: transcribe: validation

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir
    }

    private func writeWAV(to url: URL, sampleRate: Double, channels: AVAudioChannelCount, seconds: Double) throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false)!
        let frames = AVAudioFrameCount(sampleRate * seconds)
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!
        buffer.frameLength = frames
        for c in 0..<Int(channels) {
            for i in 0..<Int(frames) { buffer.floatChannelData![c][i] = sinf(Float(i) * 0.05) * 0.5 }
        }
        let file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: sampleRate, AVNumberOfChannelsKey: channels,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true,
        ])
        try file.write(from: buffer)
    }

    private func transcriber(_ provider: StubProvider) -> FileTranscriber {
        FileTranscriber(provider: { provider }, languageCode: "de")
    }

    private func assertError(_ reply: [String: Any], contains text: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(reply["ok"] as? Bool, false, file: file, line: line)
        XCTAssertEqual(reply["phase"] as? String, "error", file: file, line: line)
        XCTAssertTrue((reply["error"] as? String ?? "").contains(text), "\(reply)", file: file, line: line)
    }

    func testRejectsRelativeMissingDirectoryAndEmptyPaths() async throws {
        let dir = try tempDir()
        let empty = dir.appendingPathComponent("empty.wav")
        FileManager.default.createFile(atPath: empty.path, contents: Data())
        let t = transcriber(StubProvider(result: .success("x")))
        assertError(await t.run(path: "relative/a.wav"), contains: "absolute")
        assertError(await t.run(path: dir.appendingPathComponent("nope.wav").path), contains: "not found")
        assertError(await t.run(path: dir.path), contains: "not a regular file")
        assertError(await t.run(path: empty.path), contains: "empty")
    }

    func testRejectsNonAudioFile() async throws {
        let dir = try tempDir()
        let junk = dir.appendingPathComponent("junk.m4a")
        try Data("not audio".utf8).write(to: junk)
        assertError(await transcriber(StubProvider(result: .success("x"))).run(path: junk.path), contains: "unsupported")
    }

    // MARK: transcribe: success / error replies with a stubbed provider

    func testSuccessReplyAndDecodedInput() async throws {
        let wav = try tempDir().appendingPathComponent("a.wav")
        try writeWAV(to: wav, sampleRate: 44_100, channels: 2, seconds: 1)  // resampled + downmixed to 16 kHz mono
        var seen: TranscriptionRequest?
        let reply = await transcriber(StubProvider(result: .success("hallo welt"), onTranscribe: { seen = $0 })).run(path: wav.path)
        XCTAssertEqual(reply["ok"] as? Bool, true)
        XCTAssertEqual(reply["phase"] as? String, "success")
        XCTAssertEqual(reply["text"] as? String, "hallo welt")
        XCTAssertEqual(Double(seen?.samples.count ?? 0), 16_000, accuracy: 200)
        XCTAssertEqual(seen?.languageCode, "de")
        XCTAssertTrue(seen?.samples.contains { abs($0) > 0.1 } ?? false)
    }

    func testDecodesAACInM4A() throws {
        let m4a = try tempDir().appendingPathComponent("a.m4a")
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 44_100, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 44_100)!
        buffer.frameLength = 44_100
        for i in 0..<44_100 { buffer.floatChannelData![0][i] = sinf(Float(i) * 0.05) * 0.5 }
        do {
            let file = try AVAudioFile(forWriting: m4a, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 44_100, AVNumberOfChannelsKey: 1])
            try file.write(from: buffer)
        }  // closing the file finalizes the container
        let samples = try FileTranscriber.decode(m4a)
        XCTAssertEqual(Double(samples.count), 16_000, accuracy: 1_000)
        XCTAssertTrue(samples.contains { abs($0) > 0.1 })
    }

    func testProviderErrorBecomesErrorReply() async throws {
        let wav = try tempDir().appendingPathComponent("a.wav")
        try writeWAV(to: wav, sampleRate: 16_000, channels: 1, seconds: 1)
        assertError(await transcriber(StubProvider(result: .failure(TranscriptionError.emptyResult))).run(path: wav.path),
                    contains: "No speech")
    }

    func testReplySerializesToProtocolJSON() async throws {
        let wav = try tempDir().appendingPathComponent("a.wav")
        try writeWAV(to: wav, sampleRate: 16_000, channels: 1, seconds: 1)
        let reply = await transcriber(StubProvider(result: .success("ok"))).run(path: wav.path)
        let obj = try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: reply)) as? [String: Any]
        XCTAssertEqual(obj?["ok"] as? Bool, true)
        XCTAssertEqual(obj?["text"] as? String, "ok")
    }
}
