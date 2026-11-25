import XCTest

final class DeadlineTests: XCTestCase {
    // Regression 2026-11-25 17:44:58Z: the final Whisper pass waited forever for a model that was still
    // loading; the app stayed "transcribing" and ignored every new dictation.
    func testAnOperationThatNeverReturnsIsAbandonedAtTheDeadline() async {
        let started = Date()
        let result: String? = await withDeadline(seconds: 0.3) {
            // Ignores cancellation, like an actor that is busy loading a CoreML model.
            await withUnsafeContinuation { (_: UnsafeContinuation<Void, Never>) in }
            return "too late"
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testAFastOperationKeepsItsResult() async {
        let result = await withDeadline(seconds: 5) { "final text" }
        XCTAssertEqual(result, "final text")
    }

    func testMainActorWorkCanFinishInTime() async {
        let result = await withDeadline(seconds: 5) { @MainActor in "on main" }
        XCTAssertEqual(result, "on main")
    }

    func testLiveFinalPassDeadlineGrowsWithTheRecording() {
        XCTAssertEqual(finalPassDeadline(recordingDuration: 5), 20.5, accuracy: 0.01)
        XCTAssertEqual(finalPassDeadline(recordingDuration: 300), 50, accuracy: 0.01)
    }
}

final class VocabularyFileTests: XCTestCase {
    private var url: URL!

    override func setUp() {
        url = FileManager.default.temporaryDirectory
            .appending(path: "VocabularyFileTests-\(UUID().uuidString)/vocabulary.txt")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }

    // The first dictation after installing PR #11 created the file; that path must work with and without it.
    func testFirstUseWritesTheDefaultList() throws {
        let vocabulary = Vocabulary.load(from: url)
        XCTAssertTrue(vocabulary.terms.contains("DATEV"))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), Vocabulary.defaultText)
    }

    func testAnExistingFileIsReadAsIs() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "Orkumo\nFoo → Bar\n".write(to: url, atomically: true, encoding: .utf8)
        let vocabulary = Vocabulary.load(from: url)
        XCTAssertEqual(vocabulary.terms, ["Orkumo", "Bar"])
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "Orkumo\nFoo → Bar\n", "never overwritten")
    }
}
