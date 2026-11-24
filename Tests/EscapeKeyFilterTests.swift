import CoreGraphics
import XCTest

final class EscapeKeyFilterTests: XCTestCase {
    private let esc = EscapeKeyFilter.escapeKeyCode
    private let letterA: Int64 = 0

    func testEscOutsideRecordingPassesUntouched() {
        var filter = EscapeKeyFilter()
        XCTAssertEqual(filter.handle(type: .keyDown, keyCode: esc, flags: []), .pass)
        XCTAssertEqual(filter.handle(type: .keyUp, keyCode: esc, flags: []), .pass)
        XCTAssertFalse(filter.needsTap)
    }

    func testEscWhileRecordingIsSwallowedAndCancelsOnce() {
        var filter = EscapeKeyFilter()
        filter.arm()
        XCTAssertEqual(filter.handle(type: .keyDown, keyCode: esc, flags: []), .swallowAndCancel)
        // Auto-repeat while held: swallowed, no second cancel.
        XCTAssertEqual(filter.handle(type: .keyDown, keyCode: esc, flags: []), .swallow)
        XCTAssertEqual(filter.handle(type: .keyUp, keyCode: esc, flags: []), .swallow)
    }

    func testKeyUpIsSwallowedAfterCancelDisarmed() {
        var filter = EscapeKeyFilter()
        filter.arm()
        XCTAssertEqual(filter.handle(type: .keyDown, keyCode: esc, flags: []), .swallowAndCancel)
        filter.disarm() // the cancel ends the recording before the key is released
        XCTAssertTrue(filter.needsTap, "tap must stay on until the swallowed key-up arrives")
        XCTAssertEqual(filter.handle(type: .keyDown, keyCode: esc, flags: []), .swallow)
        XCTAssertEqual(filter.handle(type: .keyUp, keyCode: esc, flags: []), .swallow)
        XCTAssertFalse(filter.needsTap)
        XCTAssertEqual(filter.handle(type: .keyDown, keyCode: esc, flags: []), .pass)
    }

    func testKeyUpOfEscPressedBeforeRecordingPasses() {
        var filter = EscapeKeyFilter()
        filter.arm()
        XCTAssertEqual(filter.handle(type: .keyUp, keyCode: esc, flags: []), .pass)
    }

    func testOtherKeysPassWhileRecording() {
        var filter = EscapeKeyFilter()
        filter.arm()
        XCTAssertEqual(filter.handle(type: .keyDown, keyCode: letterA, flags: []), .pass)
        XCTAssertEqual(filter.handle(type: .keyUp, keyCode: letterA, flags: []), .pass)
    }

    func testModifiedEscPassesSoForceQuitStillWorks() {
        var filter = EscapeKeyFilter()
        filter.arm()
        XCTAssertEqual(filter.handle(type: .keyDown, keyCode: esc, flags: [.maskCommand, .maskAlternate]), .pass)
        XCTAssertEqual(filter.handle(type: .keyUp, keyCode: esc, flags: [.maskCommand, .maskAlternate]), .pass)
        XCTAssertEqual(filter.handle(type: .keyDown, keyCode: esc, flags: .maskControl), .pass)
        // Shift is not a command modifier: still cancels.
        XCTAssertEqual(filter.handle(type: .keyDown, keyCode: esc, flags: .maskShift), .swallowAndCancel)
    }
}
