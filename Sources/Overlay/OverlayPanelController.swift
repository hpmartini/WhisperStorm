import AppKit
import Combine
import SwiftUI

// Private SkyLight SPI (also used by iTerm2): a real, tint-free blur of what
// is behind the window. NSVisualEffectView has no radius and its alphaValue
// only fades the tint while the blur switches off (see TASK.md). Fine here:
// the app is not sandboxed and not shipped through the App Store.
private typealias CGSConnectionID = UInt32
@_silgen_name("CGSDefaultConnectionForThread")
private func CGSDefaultConnectionForThread() -> CGSConnectionID
@_silgen_name("CGSSetWindowBackgroundBlurRadius")
private func CGSSetWindowBackgroundBlurRadius(_ connection: CGSConnectionID, _ windowNumber: Int, _ radius: Int) -> Int32

/// Owns the borderless, non-activating overlay panel that shows the waveform.
/// The panel never steals focus from the frontmost app: it uses
/// `.nonactivatingPanel`, ignores mouse events and is shown with
/// `orderFrontRegardless()` instead of activating the app.
@MainActor
final class OverlayPanelController {
    private enum Layout {
        static let width: CGFloat = 340
        static let height: CGFloat = 104
        static let bottomMargin: CGFloat = 28
    }

    private let state: AppState
    private let levelStore: AudioLevelStore
    private var panel: NSPanel?
    private var hideWorkItem: DispatchWorkItem?
    private var phaseCancellable: AnyCancellable?
    private var blurCancellable: AnyCancellable?

    init(state: AppState, levelStore: AudioLevelStore) {
        self.state = state
        self.levelStore = levelStore
        phaseCancellable = state.$phase
            .receive(on: DispatchQueue.main)
            .sink { [weak self] phase in
                self?.handlePhase(phase)
            }
        // Live update while the settings slider or glass toggle changes.
        // Liquid Glass blurs on its own, so the window blur is off then.
        blurCancellable = AppSettings.shared.$overlayBlurRadius
            .combineLatest(AppSettings.shared.$overlayLiquidGlass)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.applyBlur(radius: Self.effectiveBlurRadius)
            }
    }

    private func handlePhase(_ phase: AppState.Phase) {
        switch phase {
        case .recording, .transcribing:
            show()
        case .success:
            // Keep the success flash visible briefly, then fade out.
            show()
            scheduleHide(after: 0.8)
        case .error:
            show()
            scheduleHide(after: 3.5)
        case .idle:
            fadeOut()
        }
    }

    // MARK: - Panel lifecycle

    private func show() {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        let panel = self.panel ?? makePanel()
        self.panel = panel
        attachContentIfNeeded(to: panel)
        position(panel)
        panel.alphaValue = 1
        if !panel.isVisible {
            panel.orderFrontRegardless()
        }
        applyBlur(radius: Self.effectiveBlurRadius)
    }

    private static var effectiveBlurRadius: Double {
        AppSettings.shared.usesLiquidGlass ? 0 : AppSettings.shared.overlayBlurRadius
    }

    private func applyBlur(radius: Double) {
        guard let panel, panel.windowNumber > 0 else { return }
        let status = CGSSetWindowBackgroundBlurRadius(
            CGSDefaultConnectionForThread(), panel.windowNumber, Int(radius)
        )
        if status != 0 {
            FileLog.write("OVERLAY blur radius \(Int(radius)) failed: CGError \(status)")
        }
    }

    /// Rebuilds the SwiftUI overlay when the panel is shown. The content view
    /// is torn down on hide (see fadeOut), so the 60 fps TimelineView/Canvas
    /// only exists while the overlay is actually on screen.
    private func attachContentIfNeeded(to panel: NSPanel) {
        guard panel.contentView == nil else { return }
        let hostingView = NSHostingView(
            rootView: OverlayView(state: state, levelStore: levelStore)
        )
        hostingView.frame = panel.contentRect(forFrameRect: panel.frame)
        panel.contentView = hostingView
    }

    private func scheduleHide(after delay: TimeInterval) {
        hideWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.fadeOut()
        }
        hideWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func fadeOut(duration: TimeInterval = 0.35) {
        hideWorkItem?.cancel()
        hideWorkItem = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = duration
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            panel.orderOut(nil)
            panel.alphaValue = 1
            // Tear down the SwiftUI hierarchy so no rendering/animation runs
            // while idle. It is rebuilt on the next show().
            if self?.state.phase == .idle {
                panel.contentView = nil
            }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Layout.width, height: Layout.height),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .floating
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.animationBehavior = .utilityWindow
        // The overlay is always dark-styled; in light mode Liquid Glass turns
        // milky white and the neon text becomes unreadable.
        panel.appearance = NSAppearance(named: .darkAqua)
        // Content view is attached lazily in show() and dropped on hide.
        return panel
    }

    /// Centers the panel at the bottom edge of the screen that currently has
    /// keyboard focus.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let origin = NSPoint(
            x: visible.midX - Layout.width / 2,
            y: visible.minY + Layout.bottomMargin
        )
        panel.setFrame(NSRect(origin: origin, size: NSSize(width: Layout.width, height: Layout.height)), display: true)
    }
}
