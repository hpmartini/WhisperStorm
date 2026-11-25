import Foundation
import SwiftUI

/// Observable dictation state shared between menu bar, overlay and settings.
@MainActor
final class AppState: ObservableObject {
    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case success
        case error(String)

        var isBusy: Bool {
            self == .recording || self == .transcribing
        }
    }

    @Published var phase: Phase = .idle
    @Published var lastTranscript: String = ""
    /// Extra context shown in the overlay during .transcribing
    /// (e.g. "Preparing model…" while CoreML specializes on first load).
    @Published var statusDetail: String?
    /// Warning shown in the overlay during .recording — currently only the
    /// fallback to the system default input when the selected microphone is
    /// gone. Recording from an unexpected device must never be silent.
    @Published var captureNotice: String?
    /// Live dictation: confirmed and provisional words of the running
    /// recording, shown in the overlay instead of "Listening".
    @Published var liveLine = ""
    /// Shown in the overlay's success state after a live dictation.
    @Published var finishNotice: FinishNotice?
    /// The General settings tab is open: keep the idle overlay on screen as
    /// a live preview of opacity, blur and Liquid Glass.
    @Published var overlayPreview = false

    var menuBarSymbolName: String {
        switch phase {
        case .idle, .success: "waveform"
        case .recording: "mic.fill"
        case .transcribing: "waveform.badge.magnifyingglass"
        case .error: "waveform.badge.exclamationmark"
        }
    }
}

/// The overlay's last word after a live dictation, so the end of the
/// correction is visible and not only noticed by the text changing.
enum FinishNotice: Equatable {
    /// The whole-recording pass changed the preview.
    case corrected
    /// The pass confirmed the preview as it was.
    case unchanged
    /// The pass failed or heard nothing; the live text stays.
    case correctionFailed
    /// The field stopped following; the full text is only on the clipboard.
    case pasteRest

    /// Nil when the text was pasted the classic way (nothing to confirm).
    static func after(finalPassFailed: Bool, changedPreview: Bool, delivery: FieldSync.FinalDelivery) -> FinishNotice? {
        switch delivery {
        case .paste: return nil
        case .clipboardOnly: return .pasteRest
        case .inField: return finalPassFailed ? .correctionFailed : changedPreview ? .corrected : .unchanged
        }
    }

    var text: String {
        switch self {
        case .corrected: "✓ Corrected"
        case .unchanged: "✓ No changes"
        case .correctionFailed: "Correction failed — live text kept"
        case .pasteRest: "Rest in clipboard — press ⌘V"
        }
    }

    var isWarning: Bool { self == .correctionFailed || self == .pasteRest }

    /// How long the overlay stays: a glance for confirmations, longer for warnings.
    var duration: TimeInterval { isWarning ? 3 : 1.2 }
}

/// Latest smoothed microphone level, polled by the 60 fps waveform renderer.
///
/// Deliberately not @Published: level updates arrive at buffer rate and would
/// otherwise trigger a SwiftUI invalidation storm. TimelineView polls instead.
final class AudioLevelStore: @unchecked Sendable {
    private let lock = NSLock()
    private var _level: Float = 0

    var level: Float {
        get { lock.withLock { _level } }
        set { lock.withLock { _level = newValue } }
    }
}
