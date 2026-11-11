import XCTest
@testable import WhisperStormTranscription

final class WAVEncoderTests: XCTestCase {
    func testHeaderAndClamping() {
        let data = WAVEncoder.encode(samples: [0, 1, -1, 2])
        XCTAssertEqual(data.count, 44 + 4 * 2)
        XCTAssertEqual(String(decoding: data.prefix(4), as: UTF8.self), "RIFF")
        let rate = data.subdata(in: 24..<28).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        XCTAssertEqual(rate, 16_000)
        let last = data.suffix(2).withUnsafeBytes { $0.loadUnaligned(as: Int16.self) }
        XCTAssertEqual(last, 32_767, "out-of-range samples clamp to full scale")
    }

    func testRequestDuration() {
        XCTAssertEqual(TranscriptionRequest(samples: Array(repeating: 0, count: 16_000), languageCode: "de").duration, 1)
    }
}
