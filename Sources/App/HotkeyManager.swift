import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Global dictation hotkey, default ⌥ Space.
    static let dictation = Self("dictation", default: .init(.space, modifiers: [.option]))
}
