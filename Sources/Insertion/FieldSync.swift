import Foundation

/// What live dictation has typed into the target field, and the edit that
/// brings the field to a new text using only Backspace and typing at the
/// cursor. Pure state: `LiveFieldTyper` posts the edits.
///
/// The field may only be changed while nothing else touched it: once the
/// user types or clicks, the focus moves, Secure Keyboard Entry starts or a
/// correction reaches too far back, the field is locked for the rest of the
/// recording. Its text then stays as it is and the clipboard alone carries
/// the corrected transcript.
struct FieldSync: Equatable {
    enum Lock: Equatable {
        case userInput
        case focusChanged
        case secureInput
        case cursorMoved
        case correctionTooLarge
        case typingFailed
    }

    struct Edit: Equatable {
        var deleteCount: Int
        var insert: String
    }

    /// A Whisper chunk is at most 30 s (~450 characters of speech). A longer
    /// deletion means the correction reaches before the last section.
    static let maxCorrection = 600
    /// Esc removes everything typed; beyond this it would take seconds of Backspace.
    static let maxRemoval = 3000

    /// Characters typed by us that are still in the field, ending at the cursor.
    private(set) var delivered = ""
    private(set) var lock: Lock?

    var isLocked: Bool { lock != nil }

    mutating func lock(_ reason: Lock) {
        if lock == nil { lock = reason }
    }

    /// The user typed or clicked. Before anything was typed the field is
    /// untouched (a click to place the cursor is fine), so nothing could be
    /// deleted wrongly: no lock. True when this locked the field.
    mutating func userInput(whileTyping: Bool) -> Bool {
        guard whileTyping || !delivered.isEmpty else { return false }
        lock(.userInput)
        return true
    }

    enum FinalDelivery: Equatable {
        /// The field already shows the final transcript.
        case inField
        /// Live typing never touched the field: paste the transcript like
        /// the classic mode does.
        case paste
        /// The field holds part of it; the rest is only on the clipboard.
        case clipboardOnly
    }

    static func finalDelivery(lock: Lock?, typedAnything: Bool) -> FinalDelivery {
        guard lock != nil else { return .inField }
        return typedAnything ? .clipboardOnly : .paste
    }

    /// The edit from `delivered` to `desired`: delete back to the first
    /// differing character, then type the rest. Nil when locked or nothing
    /// changes; locks when the deletion would reach too far back.
    mutating func plan(toward desired: String) -> Edit? {
        guard lock == nil else { return nil }
        let common = delivered.commonPrefix(with: desired).count
        let edit = Edit(deleteCount: delivered.count - common, insert: String(desired.dropFirst(common)))
        guard edit.deleteCount > 0 || !edit.insert.isEmpty else { return nil }
        guard edit.deleteCount <= Self.maxCorrection else {
            lock(.correctionTooLarge)
            return nil
        }
        return edit
    }

    /// Esc: deletes everything typed. Nil when locked or nothing was typed.
    func removalPlan() -> Edit? {
        guard lock == nil, !delivered.isEmpty, delivered.count <= Self.maxRemoval else { return nil }
        return Edit(deleteCount: delivered.count, insert: "")
    }

    /// The characters `edit` deletes, to check against the field first.
    func deletedText(_ edit: Edit) -> String {
        String(delivered.suffix(edit.deleteCount))
    }

    /// Records that `edit` was posted to the field.
    mutating func apply(_ edit: Edit) {
        delivered = String(delivered.dropLast(edit.deleteCount)) + edit.insert
    }
}

extension String {
    /// Common prefix in whole characters (so "ä" never splits).
    fileprivate func commonPrefix(with other: String) -> Substring {
        var end = startIndex
        var otherIndex = other.startIndex
        while end < endIndex, otherIndex < other.endIndex, self[end] == other[otherIndex] {
            end = index(after: end)
            otherIndex = other.index(after: otherIndex)
        }
        return self[startIndex..<end]
    }
}
