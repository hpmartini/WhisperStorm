import AppKit
import ApplicationServices
import Carbon.HIToolbox

/// Puts transcripts on the clipboard and pastes them into the frontmost app
/// by synthesizing Cmd+V. Requires the Accessibility permission for both the
/// focused-element check and CGEvent posting.
///
/// Note: macOS silently drops synthesized keyboard events from processes
/// without Accessibility trust — there is no error, the paste just does
/// nothing. Secure Keyboard Entry (loginwindow, password fields, some
/// terminals) blocks synthetic keystrokes even for trusted processes. Both
/// are checked and logged so a failure is never silent.
@MainActor
enum TextInserter {
    enum Outcome {
        /// Cmd+V was posted to the frontmost app.
        case pasted
        /// Text is on the clipboard only.
        case clipboardOnly(reason: String, accessibilityMissing: Bool)
    }

    private enum FocusState {
        /// A focused element was found — via the system-wide element or the
        /// frontmost app.
        case focused
        /// The Accessibility API did not report one. This does *not* mean
        /// nothing is focused: Electron/Catalyst apps (VS Code, Slack, …)
        /// answer with noValue until their AX tree is built.
        case unknown
    }

    static var isAccessibilityTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Shows the system prompt that sends the user to the Accessibility pane.
    static func promptForAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Copies `text` to the clipboard (and leaves it there — no restore of the
    /// previous clipboard), then attempts to paste into the focused text field.
    static func insert(_ text: String) -> Outcome {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        let trusted = AXIsProcessTrusted()
        let secureInput = IsSecureEventInputEnabled()
        let frontApp = NSWorkspace.shared.frontmostApplication
        FileLog.write("INSERT trusted=\(trusted) secureInput=\(secureInput) front=\(frontApp?.localizedName ?? "?")(\(frontApp?.processIdentifier ?? -1)) chars=\(text.count)")

        guard trusted else {
            Log.insertion.error("Paste skipped: Accessibility not trusted for this build")
            FileLog.write("  -> clipboard only: Accessibility NOT trusted (re-grant after rebuild)")
            return .clipboardOnly(
                reason: "Accessibility permission is missing",
                accessibilityMissing: true
            )
        }

        if secureInput {
            Log.insertion.error("Paste skipped: Secure Keyboard Entry is active")
            FileLog.write("  -> clipboard only: Secure Keyboard Entry active in the focused app")
            return .clipboardOnly(
                reason: "Secure Keyboard Entry is active in the focused app",
                accessibilityMissing: false
            )
        }

        // The focus query is diagnostic only — never a gate. The AX API
        // cannot distinguish "nothing is focused" from "this app does not
        // expose its focus", so refusing on a negative answer means never
        // inserting into Electron apps at all. Worst case of pasting anyway
        // is a Cmd+V that lands nowhere; the text is on the clipboard either
        // way.
        FileLog.write("  focusState=\(focusState())")

        guard postCmdV() else {
            Log.insertion.error("Paste skipped: could not create CGEvents")
            FileLog.write("  -> clipboard only: CGEvent creation failed")
            return .clipboardOnly(
                reason: "Could not synthesize the paste keystroke",
                accessibilityMissing: false
            )
        }
        Log.insertion.notice("Posted Cmd+V to frontmost app")
        FileLog.write("  -> posted Cmd+V ok")
        return .pasted
    }

    private static func focusState() -> FocusState {
        if focusedElement(of: AXUIElementCreateSystemWide()) != nil {
            return .focused
        }
        // The system-wide element stays empty for apps that build their AX
        // tree lazily — ask the frontmost app itself before giving up.
        if let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier,
           focusedElement(of: AXUIElementCreateApplication(pid)) != nil {
            return .focused
        }
        return .unknown
    }

    private static func focusedElement(of element: AXUIElement) -> AXUIElement? {
        var focused: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(
            element,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard result == .success, let focused else { return nil }
        return (focused as! AXUIElement)
    }

    private static func postCmdV() -> Bool {
        let vKeyCode = CGKeyCode(kVK_ANSI_V)
        // A private event source avoids merging the real current modifier
        // state (e.g. a still-held hotkey modifier in Push-to-Talk mode),
        // which could otherwise corrupt the synthesized Cmd flag.
        guard let source = CGEventSource(stateID: .privateState),
              let keyDown = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: vKeyCode, keyDown: false)
        else { return false }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        return true
    }
}
