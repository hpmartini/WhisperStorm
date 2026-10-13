import Foundation
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    /// Press once to start, again to stop. Default ⌥ Space. The storage key
    /// stays "dictation" so existing bindings survive.
    static let toggleDictation = Self("dictation", default: .init(.space, modifiers: [.option]))
    /// Hold to record, release to transcribe. Unbound by default.
    static let pushToTalk = Self("pushToTalk")

    /// Before there were two shortcuts, one shortcut plus a mode picker
    /// ("dictationMode") decided the behaviour. A push-to-talk user keeps
    /// their key, now as the push-to-talk shortcut.
    @MainActor
    static func migrateLegacyDictationMode(defaults: UserDefaults = .standard) {
        let key = "dictationMode"
        guard let mode = defaults.string(forKey: key) else { return }
        if mode == "pushToTalk" {
            KeyboardShortcuts.setShortcut(KeyboardShortcuts.getShortcut(for: .toggleDictation), for: .pushToTalk)
            KeyboardShortcuts.setShortcut(nil, for: .toggleDictation)
        }
        defaults.removeObject(forKey: key)
    }

    /// Both shortcuts on one key would fire toggle and push-to-talk at once.
    /// The settings UI prevents it; this repairs a config saved before that
    /// (or edited by hand) by unbinding push-to-talk.
    @MainActor
    static func unbindPushToTalkIfDuplicate() {
        guard let shortcut = KeyboardShortcuts.getShortcut(for: .pushToTalk),
              shortcut == KeyboardShortcuts.getShortcut(for: .toggleDictation)
        else { return }
        KeyboardShortcuts.setShortcut(nil, for: .pushToTalk)
    }
}
