import XCTest

final class FinishNoticeTests: XCTestCase {
    func testTellsWhetherTheFinalPassChangedTheText() {
        XCTAssertEqual(FinishNotice.after(finalPassFailed: false, changedPreview: true, delivery: .inField), .corrected)
        XCTAssertEqual(FinishNotice.after(finalPassFailed: false, changedPreview: false, delivery: .inField), .unchanged)
    }

    func testWarnsWhenTheCorrectionFailedOrOnlyTheClipboardHasIt() {
        XCTAssertEqual(FinishNotice.after(finalPassFailed: true, changedPreview: false, delivery: .inField), .correctionFailed)
        XCTAssertEqual(FinishNotice.after(finalPassFailed: false, changedPreview: true, delivery: .clipboardOnly), .pasteRest)
        XCTAssertTrue(FinishNotice.correctionFailed.isWarning)
        XCTAssertTrue(FinishNotice.pasteRest.isWarning)
        XCTAssertFalse(FinishNotice.corrected.isWarning)
    }

    func testPastedLikeClassicModeNeedsNoNotice() {
        XCTAssertNil(FinishNotice.after(finalPassFailed: false, changedPreview: true, delivery: .paste))
    }

    func testConfirmationsAreShortWarningsLonger() {
        XCTAssertEqual(FinishNotice.corrected.duration, 1.2, accuracy: 0.01)
        XCTAssertGreaterThanOrEqual(FinishNotice.pasteRest.duration, 3)
    }
}
