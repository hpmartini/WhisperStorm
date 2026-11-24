import XCTest
@testable import WhisperStormTranscription

final class SpeechChunkerTests: XCTestCase {
    private func tone(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * SpeechChunker.sampleRate)).map { Float(sin(Double($0) * 0.1) * 0.1) }
    }

    private func silence(_ seconds: Double) -> [Float] { Array(repeating: 0, count: Int(seconds * SpeechChunker.sampleRate)) }

    func testCutsAtPauseAfterMinDuration() {
        var c = SpeechChunker()
        XCTAssertTrue(c.append(tone(1) + silence(1)).isEmpty, "too short to cut")
        let chunks = c.append(tone(2) + silence(1))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertEqual(chunks[0].start, 0)
        XCTAssertEqual(chunks[0].duration, 4.6, accuracy: 0.03, "cut once the pause after 3 s reaches 0.6 s")
    }

    func testCutsAtMaxDuration() {
        var c = SpeechChunker()
        let chunks = c.append(tone(65))
        XCTAssertEqual(chunks.map(\.duration), [30, 30])
        XCTAssertEqual(chunks[1].start, 30)
        XCTAssertEqual(chunks[1].range, 30..<60)
        XCTAssertEqual(c.flush()?.duration ?? 0, 5, accuracy: 0.001)
    }

    func testLeadingSilenceIsDropped() {
        var c = SpeechChunker()
        let chunks = c.append(silence(10) + tone(4) + silence(1))
        XCTAssertEqual(chunks.count, 1)
        XCTAssertGreaterThanOrEqual(chunks[0].start, 9, "at most 1 s of lead-in survives")
        XCTAssertNil(c.flush())
    }

    func testFlushReturnsNilForSilence() {
        var c = SpeechChunker()
        _ = c.append(silence(5))
        XCTAssertNil(c.flush())
    }
}

final class LiveTextTests: XCTestCase {
    private func w(_ start: TimeInterval, _ text: String) -> LiveWord { LiveWord(start: start, end: start + 0.4, text: text) }

    func testWhisperReplacesOnlyLiveWordsWhoseMiddleIsInside() {
        var t = LiveText()
        t.confirm([w(1, " eins"), w(2, " zwei"), w(9.5, " drei"), w(9.9, " fünf"), w(11, " vier")], through: 12)
        t.replace(0..<10, with: "Eins, zwei, drei.")
        XCTAssertEqual(t.confirmedText, "Eins, zwei, drei. fünf vier", "fünf's middle 10.1 lies outside 0..<10")
    }

    func testLiveWordsForReplacedRangeAreDropped() {
        var t = LiveText()
        t.replace(0..<5, with: "Hallo.")
        t.confirm([w(1, " hallo"), w(6, " Welt")], through: 7)
        t.setProvisional([w(2, " spät"), w(8, " noch")])
        XCTAssertEqual(t.confirmedText, "Hallo. Welt")
        XCTAssertEqual(t.provisionalText, "noch")
    }

    func testEmptyWhisperClearsTheRange() {
        var t = LiveText()
        t.confirm([w(1, " äh")], through: 2)
        t.setProvisional([w(2.5, " hm")])
        t.replace(0..<5, with: "  \n")
        XCTAssertEqual(t.confirmedText, "")
        XCTAssertEqual(t.provisionalText, "")
    }

    func testConfirmSupersedesProvisionalUpToThrough() {
        var t = LiveText()
        t.setProvisional([w(1, " das"), w(2, " ist"), w(3, " gut")])
        t.confirm([w(1, " Das"), w(2, " ist")], through: 2.5)
        XCTAssertEqual(t.confirmedText, "Das ist")
        XCTAssertEqual(t.provisionalText, "gut")
    }

    func testConfirmedTextOrdersByStartAndHasNoNewlines() {
        var t = LiveText()
        t.confirm([w(12, " später")], through: 13)
        t.replace(0..<10, with: "Erste\nZeile\t\tund  mehr.\n")
        let text = t.confirmedText
        XCTAssertEqual(text, "Erste Zeile und mehr. später")
        XCTAssertFalse(text.contains("\n"))
    }

    func testLeadingSentenceMarkAndLonePunctuationAreDropped() {
        var t = LiveText()
        t.confirm([w(1, ". Ja"), w(2, " sehr"), w(3, " schön")], through: 4)
        t.confirm([w(5, "?")], through: 6)
        XCTAssertEqual(t.confirmedText, "Ja sehr schön")
    }

    // Regression 2026-11-24 19:59:51Z: "Sollte eigentlich schon langsamer fertig sein. sein." — Whisper put the
    // word spoken across the 3.0 s cut into chunk 1; the chunker dropped the silence after it, so chunk 2 started at
    // 3.72 s and the live "sein." (3.1–3.5 s) lay in no chunk range and stayed next to Whisper's "sein.".
    func testLiveWordInTheGapBetweenChunksDoesNotSurviveNextToWhisper() {
        var t = LiveText()
        t.confirm([w(0.1, "Sollte"), w(0.6, " eigentlich"), w(1.2, " schon"), w(1.7, " langsam"), w(2.3, " fertig")], through: 2.8)
        t.replace(0..<3.0, with: "Sollte eigentlich schon langsamer fertig sein.")
        t.confirm([LiveWord(start: 3.1, end: 3.5, text: " sein.")], through: 3.6)
        t.replace(3.72..<4.43, with: "")
        XCTAssertEqual(t.confirmedText, "Sollte eigentlich schon langsamer fertig sein.")
    }

    func testLiveWordsAfterTheLastChunkStay() {
        var t = LiveText()
        t.replace(0..<3.0, with: "Erster Satz.")
        t.confirm([w(3.5, " Zweiter"), w(4.0, " Satz.")], through: 4.5)
        XCTAssertEqual(t.confirmedText, "Erster Satz. Zweiter Satz.")
    }
}
