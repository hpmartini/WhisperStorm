import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Types live dictation into the window that was in front when the recording
/// started: Unicode key events for text, Backspace for corrections, only at
/// the cursor. `FieldSync` decides what to type; this class checks the target
/// before every burst and posts it.
///
/// Before each burst: same app and window in front, no Secure Keyboard Entry.
/// Before deleting: where the focused element exposes its text and cursor
/// (native text views), the text left of the cursor must end with what is
/// about to be deleted (catches autocorrect and app-side edits). Any failed
/// check locks the field for the rest of the recording.
@MainActor
final class LiveFieldTyper {
    /// A burst is posted only this long after the previous one ended, so the
    /// Accessibility read before a deletion sees the field after our typing.
    private static let settleTime: TimeInterval = 0.15
    private nonisolated static let eventGap: useconds_t = 1500

    private(set) var sync = FieldSync()
    let targetName: String
    private let targetPID: pid_t
    private let targetWindow: AXUIElement?
    private let abort: AbortFlag
    private let postQueue = DispatchQueue(label: "whisperstorm.live.typing", qos: .userInteractive)
    private var desired = ""
    private var posting = false
    private var pumpScheduled = false
    private var lastBurstEnd = Date.distantPast

    /// Called once when the field gets locked.
    var onLock: ((FieldSync.Lock) -> Void)?
    /// Called on the main actor after a burst that typed text reached the field.
    var onTyped: (() -> Void)?

    /// Nil when no app is in front.
    init?(abort: AbortFlag) {
        guard let app = NSWorkspace.shared.frontmostApplication else { return nil }
        targetPID = app.processIdentifier
        targetName = app.localizedName ?? "pid \(app.processIdentifier)"
        targetWindow = Self.focusedWindow(of: app.processIdentifier)
        self.abort = abort
    }

    var isIdle: Bool {
        var probe = sync
        return !posting && !pumpScheduled && (probe.isLocked || probe.plan(toward: desired) == nil)
    }

    func lock(_ reason: FieldSync.Lock) {
        abort.set()
        guard !sync.isLocked else { return }
        sync.lock(reason)
        FileLog.write("LIVE field locked: \(reason) (typed chars=\(sync.delivered.count))")
        onLock?(reason)
    }

    /// The field should show `text`; posts the difference as soon as it is safe.
    func update(to text: String) {
        desired = text
        pump()
    }

    /// Waits until everything is typed or the field is locked (at most `timeout`).
    func settle(timeout: TimeInterval = 15) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !isIdle, Date() < deadline {
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    /// Esc: deletes what we typed, if the field is still ours.
    func removeTyped() async {
        desired = ""
        pump(removal: true)
        await settle()
    }

    private func pump(removal: Bool = false) {
        guard !posting, !sync.isLocked else { return }
        var plannedSync = sync
        let planned = removal ? sync.removalPlan() : plannedSync.plan(toward: desired)
        if plannedSync.isLocked, let reason = plannedSync.lock { return lock(reason) }
        guard let edit = planned else { return }

        let wait = Self.settleTime - Date().timeIntervalSince(lastBurstEnd)
        if wait > 0 {
            guard !pumpScheduled else { return }
            pumpScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self] in
                self?.pumpScheduled = false
                self?.pump(removal: removal)
            }
            return
        }
        if let reason = targetProblem() { return lock(reason) }
        if edit.deleteCount > 0,
           let before = Self.textBeforeCursor(),
           !before.hasSuffix(sync.deletedText(edit)) {
            FileLog.write("LIVE cursor check failed: field does not end with the text to delete")
            return lock(.cursorMoved)
        }

        sync.apply(edit)
        // Counts only, never the text.
        FileLog.write("LIVE field \(edit.deleteCount > 0 ? "correct" : "type") -\(edit.deleteCount) +\(edit.insert.count)")
        posting = true
        let abort = abort
        postQueue.async {
            let posted = Self.post(edit, abort: abort)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                posting = false
                lastBurstEnd = Date()
                if !posted { lock(.typingFailed) }
                if posted, !edit.insert.isEmpty { onTyped?() }
                pump()
            }
        }
    }

    private func targetProblem() -> FieldSync.Lock? {
        if IsSecureEventInputEnabled() { return .secureInput }
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == targetPID else { return .focusChanged }
        if let targetWindow, let window = Self.focusedWindow(of: targetPID), !CFEqual(targetWindow, window) {
            return .focusChanged
        }
        return nil
    }

    // MARK: - Posting (post queue)

    /// False when events could not be created. Stops early, without error,
    /// once the abort flag is set (the field is locked by then).
    private nonisolated static func post(_ edit: FieldSync.Edit, abort: AbortFlag) -> Bool {
        guard let source = CGEventSource(stateID: .privateState) else { return false }
        for _ in 0..<edit.deleteCount {
            guard !abort.isSet else { return true }
            guard postKey(CGKeyCode(kVK_Delete), text: nil, source: source) else { return false }
        }
        // One character per event: some apps read only the first character of a multi-character Unicode event.
        for character in edit.insert {
            guard !abort.isSet else { return true }
            guard postKey(0, text: Array(String(character).utf16), source: source) else { return false }
        }
        return true
    }

    private nonisolated static func postKey(_ key: CGKeyCode, text: [UniChar]?, source: CGEventSource) -> Bool {
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false)
        else { return false }
        for event in [down, up] {
            // A held push-to-talk modifier must not turn text into shortcuts.
            event.flags = []
            event.setIntegerValueField(.eventSourceUserData, value: UserInputClassifier.syntheticEventTag)
            if let text { event.keyboardSetUnicodeString(stringLength: text.count, unicodeString: text) }
        }
        down.post(tap: .cghidEventTap)
        up.post(tap: .cghidEventTap)
        usleep(eventGap)
        return true
    }

    // MARK: - Accessibility

    private static func focusedWindow(of pid: pid_t) -> AXUIElement? {
        copyElement(AXUIElementCreateApplication(pid), kAXFocusedWindowAttribute)
    }

    /// Text left of the cursor in the focused element; nil when the element
    /// does not expose a plain text value with a collapsed selection
    /// (terminals, Electron apps, web views).
    private static func textBeforeCursor() -> String? {
        guard let element = copyElement(AXUIElementCreateSystemWide(), kAXFocusedUIElementAttribute) else { return nil }
        var roleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        guard let role = roleRef as? String,
              role == kAXTextFieldRole || role == kAXTextAreaRole || role == kAXComboBoxRole
        else { return nil }
        var valueRef: CFTypeRef?
        var rangeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &valueRef) == .success,
              let value = valueRef as? String,
              AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &rangeRef) == .success,
              let rangeRef, CFGetTypeID(rangeRef) == AXValueGetTypeID()
        else { return nil }
        var range = CFRange()
        guard AXValueGetValue(rangeRef as! AXValue, .cfRange, &range), range.length == 0 else { return nil }
        let utf16 = value.utf16
        guard range.location >= 0, range.location <= utf16.count,
              let end = utf16.index(utf16.startIndex, offsetBy: range.location, limitedBy: utf16.endIndex)
        else { return nil }
        return String(value[..<end])
    }

    private static func copyElement(_ element: AXUIElement, _ attribute: String) -> AXUIElement? {
        var ref: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &ref) == .success,
              let ref, CFGetTypeID(ref) == AXUIElementGetTypeID()
        else { return nil }
        return (ref as! AXUIElement)
    }
}

/// Set from the key tap thread the moment the user types or clicks, checked
/// between posted events so a running burst stops right away.
final class AbortFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    var isSet: Bool { lock.withLock { value } }
    func set() { lock.withLock { value = true } }
}
