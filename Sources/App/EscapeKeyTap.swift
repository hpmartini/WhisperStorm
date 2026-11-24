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

/// Active CGEventTap that swallows Esc while a recording runs, so cancelling
/// dictation never reaches the frontmost app (a running agent in a terminal
/// or chat would abort on it). `NSEvent` global monitors can only observe.
///
/// Requires Accessibility; without it `arm()` returns false.
/// The tap runs on its own thread: capture start can block the main actor
/// for seconds, and a tap on a blocked run loop delays every keystroke
/// system-wide until macOS disables it. Outside a recording the tap is
/// disabled, so normal typing never passes through it.
/// Secure Keyboard Entry hides keystrokes from all taps; Esc then reaches the
/// focused app and does not cancel.
final class EscapeKeyTap: @unchecked Sendable {
    private let lock = NSLock()
    private var filter = EscapeKeyFilter()
    private var tap: CFMachPort?
    /// Called on the main queue for each Esc press that cancels.
    private let onEscape: @Sendable () -> Void

    init(onEscape: @escaping @Sendable () -> Void) {
        self.onEscape = onEscape
    }

    /// Starts swallowing Esc. False when the tap cannot be created
    /// (Accessibility not granted to this build).
    func arm() -> Bool {
        guard let tap = tap ?? makeTap() else { return false }
        lock.withLock { filter.arm() }
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func disarm() {
        let keepEnabled = lock.withLock {
            filter.disarm()
            return filter.needsTap
        }
        if !keepEnabled, let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
    }

    private func makeTap() -> CFMachPort? {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, userInfo in
                guard let userInfo else { return Unmanaged.passUnretained(event) }
                let owner = Unmanaged<EscapeKeyTap>.fromOpaque(userInfo).takeUnretainedValue()
                return owner.handle(type: type, event: event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            FileLog.write("ESC tap: creation failed (Accessibility not granted?)")
            return nil
        }
        tap = port
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
            CFRunLoopRun()
        }
        thread.name = "WhisperStorm.EscapeKeyTap"
        thread.qualityOfService = .userInteractive
        thread.start()
        return port
    }

    /// Runs on the tap thread for every key event while the tap is enabled.
    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // Our own tapEnable(false) also arrives here as `tapDisabledByUserInput`;
        // only a disable while the tap is still needed is the system's doing.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if lock.withLock({ filter.needsTap }), let tap {
                FileLog.write("ESC tap: disabled by system (\(type == .tapDisabledByTimeout ? "timeout" : "user input")), re-enabling")
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let (decision, stillNeeded) = lock.withLock {
            (filter.handle(type: type, keyCode: keyCode, flags: event.flags), filter.needsTap)
        }
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
