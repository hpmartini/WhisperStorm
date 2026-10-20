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
