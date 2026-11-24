import AppKit
import XCTest

@MainActor
final class ClipboardMirrorTests: XCTestCase {
    private let transient = NSPasteboard.PasteboardType("org.nspasteboard.TransientType")
    private var board: NSPasteboard!

    override func setUp() {
        board = NSPasteboard.withUniqueName()
        board.clearContents()
        board.setString("user copied this", forType: .string)
    }

    override func tearDown() {
        board.releaseGlobally()
    }

    func testIntermediateStatesAreTransientAndFinalIsANormalEntry() {
        let mirror = ClipboardMirror(pasteboard: board)
        mirror.writeTransient("Hallo")
        XCTAssertEqual(board.string(forType: .string), "Hallo")
        XCTAssertEqual(board.pasteboardItems?.count, 1, "text and marker travel in one item")
        XCTAssertTrue(board.types?.contains(transient) == true)

        mirror.writeFinal("Hallo Welt.")
        XCTAssertEqual(board.string(forType: .string), "Hallo Welt.")
        XCTAssertFalse(board.types?.contains(transient) == true, "history apps must record the final text")
    }

    func testEscRestoresWhatWasThereBeforeTheRecording() {
        let mirror = ClipboardMirror(pasteboard: board)
        mirror.writeTransient("verworfen")
        mirror.writeTransient("verworfen und mehr")
        mirror.restore()
        XCTAssertEqual(board.string(forType: .string), "user copied this")
        XCTAssertFalse(board.types?.contains(transient) == true)
    }

    func testRestoreLeavesANewerCopyByTheUserAlone() {
        let mirror = ClipboardMirror(pasteboard: board)
        mirror.writeTransient("verworfen")
        board.clearContents()
        board.setString("copied during the recording", forType: .string)
        mirror.restore()
        XCTAssertEqual(board.string(forType: .string), "copied during the recording")
    }

    func testRestoreWithoutAnyLiveWriteChangesNothing() {
        let mirror = ClipboardMirror(pasteboard: board)
        let before = board.changeCount
        mirror.restore()
        XCTAssertEqual(board.changeCount, before)
    }
}
