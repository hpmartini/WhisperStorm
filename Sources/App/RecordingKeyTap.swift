import CoreGraphics
import Foundation

/// Decides what happens to a keyboard event while the Esc tap runs.
/// Pure state, no event tap, so the rules are unit-testable.
struct EscapeKeyFilter {
    enum Decision: Equatable {
        case pass
        case swallow
        /// First Esc press while armed: swallow it and cancel the recording.
        case swallowAndCancel
    }

    static let escapeKeyCode: Int64 = 53

    /// Armed while a recording runs; outside a recording Esc passes untouched.
    private(set) var armed = false
    /// A swallowed Esc key-down whose key-up has not arrived. Its auto-repeats
    /// and the key-up are swallowed too, even after disarming, so the
    /// frontmost app never sees half a key press.
    private(set) var holdingSwallowedKey = false

    /// The tap must stay enabled while this is true.
    var needsTap: Bool { armed || holdingSwallowedKey }

    mutating func arm() { armed = true }
    mutating func disarm() { armed = false }

    mutating func handle(type: CGEventType, keyCode: Int64, flags: CGEventFlags) -> Decision {
        guard keyCode == Self.escapeKeyCode else { return .pass }
        switch type {
        case .keyDown:
            if holdingSwallowedKey { return .swallow }
            // ⌘⌥Esc (Force Quit) and other modified Esc combos are not ours.
            guard armed, flags.isDisjoint(with: [.maskCommand, .maskAlternate, .maskControl]) else {
                return .pass
            }
            holdingSwallowedKey = true
            return .swallowAndCancel
        case .keyUp:
            guard holdingSwallowedKey else { return .pass }
            holdingSwallowedKey = false
            return .swallow
        default:
            return .pass
        }
    }
}

/// Which events during live dictation mean the user touched the target
/// field: any click, or a key press that is neither ours, Esc, nor one of
/// the dictation shortcuts. Modifier changes and key-ups never count.
struct UserInputClassifier {
    struct Shortcut: Equatable {
        let keyCode: Int64
        let flags: CGEventFlags
    }

    /// Set in `eventSourceUserData` of every event live typing posts.
    static let syntheticEventTag: Int64 = 0x5753_4C56
    static let commandModifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]

    var dictationShortcuts: [Shortcut] = []

    func isUserInput(type: CGEventType, keyCode: Int64, flags: CGEventFlags, userData: Int64) -> Bool {
        guard userData != Self.syntheticEventTag else { return false }
        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return true
        case .keyDown:
            guard keyCode != EscapeKeyFilter.escapeKeyCode else { return false }
            let held = flags.intersection(Self.commandModifiers)
            return !dictationShortcuts.contains { $0.keyCode == keyCode && $0.flags == held }
        default:
            return false
        }
    }
}

/// Active CGEventTap that runs only around a recording:
/// - swallows Esc while recording, so cancelling never reaches the frontmost
///   app (a running agent in a terminal or chat would abort on it);
///   `NSEvent` global monitors can only observe;
/// - while live dictation types, reports the user's own key presses and
///   clicks, so typing stops before it could delete the wrong text.
///
/// Requires Accessibility; without it `start` returns false.
/// The tap runs on its own thread: capture start can block the main actor
/// for seconds, and a tap on a blocked run loop delays every keystroke
/// system-wide until macOS disables it. Outside a recording the tap is
/// disabled, so normal typing never passes through it.
/// Secure Keyboard Entry hides keystrokes from all taps; Esc then reaches the
/// focused app and does not cancel.
final class RecordingKeyTap: @unchecked Sendable {
    private let lock = NSLock()
    private var escape = EscapeKeyFilter()
    private var classifier = UserInputClassifier()
    private var watchingInput = false
    private var tap: CFMachPort?
    /// Called on the main queue for each Esc press that cancels.
    private let onEscape: @Sendable () -> Void
    /// Called on the tap thread, before the event reaches any app.
    private let onUserInput: @Sendable () -> Void

    init(onEscape: @escaping @Sendable () -> Void, onUserInput: @escaping @Sendable () -> Void) {
        self.onEscape = onEscape
        self.onUserInput = onUserInput
    }

    /// Starts swallowing Esc and, with `watchInput`, reporting user input.
    /// False when the tap cannot be created (Accessibility not granted).
    func start(watchInput: Bool, dictationShortcuts: [UserInputClassifier.Shortcut]) -> Bool {
        guard let tap = tap ?? makeTap() else { return false }
        lock.withLock {
            escape.arm()
            watchingInput = watchInput
            classifier.dictationShortcuts = dictationShortcuts
        }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    /// Recording ended: Esc passes again. Input watching continues until
    /// `stopWatchingInput`, because live typing finishes after the recording.
    func stopEscape() {
        lock.withLock { escape.disarm() }
        disableIfUnneeded()
    }

    func stopWatchingInput() {
        lock.withLock { watchingInput = false }
        disableIfUnneeded()
    }

    func stop() {
        lock.withLock {
            escape.disarm()
            watchingInput = false
        }
        disableIfUnneeded()
    }

    private var needsTap: Bool { escape.needsTap || watchingInput }

    private func disableIfUnneeded() {
        if !lock.withLock({ needsTap }), let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    private func makeTap() -> CFMachPort? {
        let types: [CGEventType] = [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        let mask = types.reduce(CGEventMask(0)) { $0 | CGEventMask(1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<RecordingKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            FileLog.write("KEY tap: creation failed (Accessibility not granted?)")
            return nil
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "WhisperStorm.RecordingKeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return port
    }

    /// Runs on the tap thread for every event while the tap is enabled.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Our own tapEnable(false) also arrives here as `tapDisabledByUserInput`;
        // only a disable while the tap is still needed is the system's doing.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if lock.withLock({ needsTap }), let tap {
                FileLog.write("KEY tap: disabled by system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let userData = event.getIntegerValueField(.eventSourceUserData)
        let (decision, isUserInput, stillNeeded) = lock.withLock {
            let isKey = type == .keyDown || type == .keyUp
            let decision = isKey ? escape.handle(type: type, keyCode: keyCode, flags: event.flags) : .pass
            let isUserInput = watchingInput
                && classifier.isUserInput(type: type, keyCode: keyCode, flags: event.flags, userData: userData)
            return (decision, isUserInput, needsTap)
        }
        if isUserInput { onUserInput() }
        switch decision {
        case .pass:
            return Unmanaged.passUnretained(event)
        case .swallow:
            if !stillNeeded, let tap {
                CGEvent.tapEnable(tap: tap, enable: false)
            }
            return nil
        case .swallowAndCancel:
            FileLog.write("ESC swallowed during recording")
            DispatchQueue.main.async(execute: onEscape)
            return nil
        }
    }
}
