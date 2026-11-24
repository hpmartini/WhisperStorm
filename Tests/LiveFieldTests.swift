import CoreGraphics
import XCTest

final class FieldSyncTests: XCTestCase {
    func testAppendsNewConfirmedTextWithoutDeleting() {
        var sync = FieldSync()
        let first = sync.plan(toward: "Hallo Welt")
        XCTAssertEqual(first, .init(deleteCount: 0, insert: "Hallo Welt"))
        sync.apply(first!)
        XCTAssertEqual(sync.plan(toward: "Hallo Welt, wie geht's"), .init(deleteCount: 0, insert: ", wie geht's"))
    }

    func testCorrectionDeletesBackToFirstDifferenceOnly() {
        var sync = FieldSync()
        sync.apply(sync.plan(toward: "Das ist ein Test. Hallo Welt wie gets")!)
        // Whisper corrects the last section; the first sentence is untouched.
        let edit = sync.plan(toward: "Das ist ein Test. Hallo Welt, wie geht's?")
        XCTAssertEqual(edit, .init(deleteCount: 9, insert: ", wie geht's?"))
        XCTAssertEqual(sync.deletedText(edit!), " wie gets")
        sync.apply(edit!)
        XCTAssertEqual(sync.delivered, "Das ist ein Test. Hallo Welt, wie geht's?")
    }

    func testUmlautsCountAsOneCharacterForBackspace() {
        var sync = FieldSync()
        sync.apply(sync.plan(toward: "Grüße")!)
        // "e\u{301}" vs "é": a decomposed character is still one Backspace.
        XCTAssertEqual(sync.plan(toward: "Grü"), .init(deleteCount: 2, insert: ""))
        sync.apply(sync.plan(toward: "Grü")!)
        sync.apply(sync.plan(toward: "Grüe\u{301}")!)
        XCTAssertEqual(sync.plan(toward: "Grü"), .init(deleteCount: 1, insert: ""))
    }

    func testNothingToDoReturnsNil() {
        var sync = FieldSync()
        sync.apply(sync.plan(toward: "gleich")!)
        XCTAssertNil(sync.plan(toward: "gleich"))
    }

    func testLockedFieldIsNeverEditedAgain() {
        var sync = FieldSync()
        sync.apply(sync.plan(toward: "Hallo wie gets")!)
        sync.lock(.userInput)
        XCTAssertNil(sync.plan(toward: "Hallo, wie geht's"), "user typed: corrections go to the clipboard only")
        XCTAssertNil(sync.plan(toward: "Hallo wie gets und weiter"), "no new text either")
        XCTAssertNil(sync.removalPlan(), "Esc must not delete after the user typed")
        sync.lock(.focusChanged)
        XCTAssertEqual(sync.lock, .userInput, "first reason wins")
    }

    func testCorrectionReachingBeforeTheLastSectionLocksInsteadOfDeleting() {
        var sync = FieldSync()
        let long = String(repeating: "wort ", count: 200)  // 1000 characters
        sync.apply(sync.plan(toward: long)!)
        XCTAssertNil(sync.plan(toward: "Wort " + long.dropFirst(5)))
        XCTAssertEqual(sync.lock, .correctionTooLarge)
    }

    func testCorrectionWithinTheLimitIsAllowed() {
        var sync = FieldSync()
        let section = String(repeating: "x", count: FieldSync.maxCorrection)
        sync.apply(sync.plan(toward: "Satz. " + section)!)
        XCTAssertEqual(sync.plan(toward: "Satz. y")?.deleteCount, FieldSync.maxCorrection)
        XCTAssertFalse(sync.isLocked)
    }

    func testEscRemovesEverythingTyped() {
        var sync = FieldSync()
        sync.apply(sync.plan(toward: "Diktat")!)
        let removal = sync.removalPlan()
        XCTAssertEqual(removal, .init(deleteCount: 6, insert: ""))
        sync.apply(removal!)
        XCTAssertEqual(sync.delivered, "")
        XCTAssertNil(sync.removalPlan())
    }

    func testEmptyWhisperClearingTheTailDeletesIt() {
        var sync = FieldSync()
        sync.apply(sync.plan(toward: "Satz eins. äh")!)
        XCTAssertEqual(sync.plan(toward: "Satz eins."), .init(deleteCount: 3, insert: ""))
    }

    // Regression 2026-11-24 15:23:32Z: a click before any word was typed locked the
    // field, nothing reached it, the transcript ended up on the clipboard only.
    func testInputBeforeAnyTypingKeepsTheFieldOurs() {
        var sync = FieldSync()
        XCTAssertFalse(sync.userInput(whileTyping: false))
        XCTAssertFalse(sync.isLocked)
        XCTAssertEqual(sync.plan(toward: "Hallo"), .init(deleteCount: 0, insert: "Hallo"), "typing still starts")
    }

    func testInputAfterTypingLocks() {
        var sync = FieldSync()
        sync.apply(sync.plan(toward: "Hallo")!)
        XCTAssertTrue(sync.userInput(whileTyping: false))
        XCTAssertEqual(sync.lock, .userInput)
    }

    func testInputDuringTheFirstBurstLocks() {
        // The burst may be cut off half-way: the field no longer matches what we think we typed.
        var sync = FieldSync()
        XCTAssertTrue(sync.userInput(whileTyping: true))
        XCTAssertEqual(sync.lock, .userInput)
    }

    func testFinalDelivery() {
        XCTAssertEqual(FieldSync.finalDelivery(lock: nil, typedAnything: true), .inField)
        XCTAssertEqual(FieldSync.finalDelivery(lock: .userInput, typedAnything: false), .paste,
                       "field untouched: paste like the classic mode instead of clipboard only")
        XCTAssertEqual(FieldSync.finalDelivery(lock: .focusChanged, typedAnything: false), .paste)
        XCTAssertEqual(FieldSync.finalDelivery(lock: .typingFailed, typedAnything: false), .paste)
        XCTAssertEqual(FieldSync.finalDelivery(lock: .userInput, typedAnything: true), .clipboardOnly,
                       "part is in the field: never paste the whole text on top")
    }
}

final class UserInputClassifierTests: XCTestCase {
    private let space: Int64 = 49
    private let letterA: Int64 = 0

    private var classifier: UserInputClassifier {
        var classifier = UserInputClassifier()
        classifier.dictationShortcuts = [.init(keyCode: space, flags: .maskAlternate)]
        return classifier
    }

    func testUserKeyPressAndClicksCount() {
        XCTAssertTrue(classifier.isUserInput(type: .keyDown, keyCode: letterA, flags: [], userData: 0))
        XCTAssertTrue(classifier.isUserInput(type: .keyDown, keyCode: 123, flags: [], userData: 0), "arrow key moves the cursor")
        XCTAssertTrue(classifier.isUserInput(type: .leftMouseDown, keyCode: 0, flags: [], userData: 0))
        XCTAssertTrue(classifier.isUserInput(type: .rightMouseDown, keyCode: 0, flags: [], userData: 0))
    }

    func testOwnTypingDoesNotCount() {
        XCTAssertFalse(classifier.isUserInput(
            type: .keyDown, keyCode: letterA, flags: [], userData: UserInputClassifier.syntheticEventTag
        ))
    }

    func testDictationShortcutEscAndKeyUpsDoNotCount() {
        XCTAssertFalse(classifier.isUserInput(type: .keyDown, keyCode: space, flags: .maskAlternate, userData: 0))
        XCTAssertFalse(classifier.isUserInput(type: .keyDown, keyCode: EscapeKeyFilter.escapeKeyCode, flags: [], userData: 0))
        XCTAssertFalse(classifier.isUserInput(type: .keyUp, keyCode: letterA, flags: [], userData: 0))
        XCTAssertFalse(classifier.isUserInput(type: .flagsChanged, keyCode: 58, flags: .maskAlternate, userData: 0))
    }

    func testPointerMovesScrollsAndModifiersDoNotCount() {
        for type: CGEventType in [.mouseMoved, .scrollWheel, .leftMouseDragged, .leftMouseUp, .flagsChanged] {
            XCTAssertFalse(classifier.isUserInput(type: type, keyCode: 0, flags: [], userData: 0), "\(type.rawValue)")
        }
    }

    func testSameKeyWithOtherModifiersCounts() {
        XCTAssertTrue(classifier.isUserInput(type: .keyDown, keyCode: space, flags: [], userData: 0), "plain space is typing")
        XCTAssertTrue(classifier.isUserInput(type: .keyDown, keyCode: space, flags: [.maskAlternate, .maskShift], userData: 0))
        // Caps Lock / Fn do not change the match.
        XCTAssertFalse(classifier.isUserInput(type: .keyDown, keyCode: space, flags: [.maskAlternate, .maskAlphaShift], userData: 0))
    }
}
