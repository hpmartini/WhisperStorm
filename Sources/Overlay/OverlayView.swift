import SwiftUI

enum CyberpunkPalette {
    // Neon cyan #00FFF7, magenta #FF2BD6, violet #7A2BFF
    static let cyan = Color(red: 0, green: 1.0, blue: 0.969)
    static let magenta = Color(red: 1.0, green: 0.169, blue: 0.839)
    static let violet = Color(red: 0.478, green: 0.169, blue: 1.0)
    static let errorRed = Color(red: 1.0, green: 0.22, blue: 0.29)
    static let errorOrange = Color(red: 1.0, green: 0.45, blue: 0.15)

    static let waveGradient = Gradient(colors: [cyan, magenta, violet])
    static let errorGradient = Gradient(colors: [errorRed, errorOrange, errorRed])
}

/// Dark-glass pill with the cyberpunk waveform and a status line.
struct OverlayView: View {
    @ObservedObject var state: AppState
    let levelStore: AudioLevelStore

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(.ultraThinMaterial)
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(Color.black.opacity(0.55))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .strokeBorder(
                            LinearGradient(
                                gradient: borderGradient,
                                startPoint: .leading,
                                endPoint: .trailing
                            ),
                            lineWidth: 1
                        )
                        .opacity(0.45)
                )

            VStack(spacing: 4) {
                WaveformCanvas(state: state, levelStore: levelStore)
                    .frame(height: 52)
                    .padding(.horizontal, 18)

                statusLine
                    .frame(height: 16)
            }
            .padding(.vertical, 12)
        }
        .frame(width: 340, height: 104)
    }

    private var borderGradient: Gradient {
        if case .error = state.phase {
            return CyberpunkPalette.errorGradient
        }
        return CyberpunkPalette.waveGradient
    }

    @ViewBuilder
    private var statusLine: some View {
        switch state.phase {
        case .recording:
            Text(state.captureNotice ?? "Listening — esc to cancel")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(
                    state.captureNotice == nil
                        ? CyberpunkPalette.cyan.opacity(0.65)
                        : CyberpunkPalette.errorRed
                )
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
        case .transcribing:
            Text(state.statusDetail ?? "Transcribing…")
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(CyberpunkPalette.magenta.opacity(0.85))
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 12)
        case .error(let message):
            Text(message)
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(CyberpunkPalette.errorRed)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, 16)
        case .success, .idle:
            Text("")
                .font(.system(size: 11))
        }
    }
}

/// 60 fps waveform renderer: TimelineView drives a Canvas that polls the
/// current mic level and animates per-bar sine modulation.
private struct WaveformCanvas: View {
    @ObservedObject var state: AppState
    let levelStore: AudioLevelStore
    @State private var model = WaveformModel()

    var body: some View {
        // Pause the 60 fps timeline whenever the overlay is at rest. Without
        // this, SwiftUI keeps re-rendering the Canvas at display refresh rate
        // even while the panel is hidden, burning CPU in the idle state.
        TimelineView(.animation(minimumInterval: nil, paused: isPaused)) { timeline in
            Canvas { context, size in
                model.draw(
                    in: &context,
                    size: size,
                    time: timeline.date.timeIntervalSinceReferenceDate,
                    phase: state.phase,
                    level: levelStore.level
                )
            }
        }
    }

    /// The overlay is only ever on screen during recording/transcribing and
    /// the brief success/error tail. In `.idle` the panel is hidden, so there
    /// is nothing to animate.
    private var isPaused: Bool {
        state.phase == .idle
    }
}

/// Holds cross-frame animation state (envelope, phase transitions) outside of
/// SwiftUI so the Canvas can render at 60 fps without view invalidation.
private final class WaveformModel {
    private struct BarSeed {
        let frequency: Double
        let phase: Double
        let weight: Double
    }

    private let barCount = 48
    private let minBarHeight: CGFloat = 2.5
    private var seeds: [BarSeed]
    private var displayLevel: CGFloat = 0
    private var lastPhase: AppState.Phase = .idle
    private var phaseStartTime: TimeInterval = 0

    init() {
        // Deterministic pseudo-random per-bar modulation seeds.
        var generator = SystemRandomNumberGenerator()
        seeds = (0..<barCount).map { _ in
            BarSeed(
                frequency: Double.random(in: 5.5...11.0, using: &generator),
                phase: Double.random(in: 0...(2 * .pi), using: &generator),
                weight: Double.random(in: 0.6...1.0, using: &generator)
            )
        }
    }

    func draw(
        in context: inout GraphicsContext,
        size: CGSize,
        time: TimeInterval,
        phase: AppState.Phase,
        level: Float
    ) {
        if phase != lastPhase {
            lastPhase = phase
            phaseStartTime = time
        }
        let elapsed = time - phaseStartTime

        // Attack/release envelope towards the live mic level.
        let target = CGFloat(level)
        let coefficient: CGFloat = target > displayLevel ? 0.35 : 0.07
        displayLevel += (target - displayLevel) * coefficient

        let heights = barHeights(size: size, time: time, phase: phase, elapsed: elapsed)
        let gradient: Gradient = isError(phase) ? CyberpunkPalette.errorGradient : CyberpunkPalette.waveGradient
        let shading = GraphicsContext.Shading.linearGradient(
            gradient,
            startPoint: .zero,
            endPoint: CGPoint(x: size.width, y: 0)
        )

        // Neon glow: blurred additive duplicate below the crisp layer.
        context.drawLayer { layer in
            layer.addFilter(.blur(radius: 6))
            layer.blendMode = .plusLighter
            layer.opacity = 0.85
            drawBars(into: layer, heights: heights, size: size, shading: shading, phase: phase, time: time, elapsed: elapsed)
        }
        drawBars(into: context, heights: heights, size: size, shading: shading, phase: phase, time: time, elapsed: elapsed)

        // Success flash: bright white overlay that decays quickly.
        if case .success = phase {
            let flash = max(0, 1 - elapsed / 0.45)
            if flash > 0 {
                let flashShading = GraphicsContext.Shading.color(.white.opacity(flash * 0.9))
                drawBars(into: context, heights: heights, size: size, shading: flashShading, phase: phase, time: time, elapsed: elapsed)
            }
        }

        drawScanlines(into: &context, size: size)
    }

    // MARK: - Geometry

    private func barHeights(
        size: CGSize,
        time: TimeInterval,
        phase: AppState.Phase,
        elapsed: TimeInterval
    ) -> [CGFloat] {
        let maxHeight = size.height - 4
        return (0..<barCount).map { index in
            let normalizedX = Double(index) / Double(barCount - 1)
            // Gaussian window: emphasize the center, taper the edges.
            let window = exp(-pow((normalizedX - 0.5) / 0.38, 2))
            let seed = seeds[index]

            switch phase {
            case .idle:
                // Nearly flat line, gently breathing.
                let breath = 0.5 + 0.5 * sin(time * 1.3 + Double(index) * 0.22)
                return minBarHeight + CGFloat(2.2 * breath * window)

            case .recording:
                let speed = 1.0 + 1.6 * Double(displayLevel)
                let wobble = 0.55 + 0.45 * sin(time * seed.frequency * speed + seed.phase)
                let amplitude = Double(displayLevel) * Double(maxHeight) * window * seed.weight * wobble
                let breath = 1.5 * (0.5 + 0.5 * sin(time * 1.3 + Double(index) * 0.22)) * window
                return minBarHeight + CGFloat(max(breath, amplitude))

            case .transcribing:
                // Medium standing wave with a shimmer band sweeping across.
                let wobble = 0.5 + 0.5 * sin(time * seed.frequency * 0.7 + seed.phase)
                let base = 0.28 * Double(maxHeight) * window * wobble
                let shimmer = shimmerBoost(normalizedX: normalizedX, time: time)
                return minBarHeight + CGFloat(base * (1 + 1.1 * shimmer))

            case .success:
                let flash = max(0, 1 - elapsed / 0.45)
                let wobble = 0.5 + 0.5 * sin(time * seed.frequency + seed.phase)
                let base = 0.3 * Double(maxHeight) * window * wobble
                return minBarHeight + CGFloat(base * (1 + 1.4 * flash))

            case .error:
                // Glitch: jittery random heights, re-rolled a few times a second.
                let bucket = Int(time * 18)
                let jitter = pseudoRandom(index: index, bucket: bucket)
                return minBarHeight + CGFloat(jitter * 0.5 * Double(maxHeight) * (0.4 + 0.6 * window))
            }
        }
    }

    private func drawBars(
        into context: GraphicsContext,
        heights: [CGFloat],
        size: CGSize,
        shading: GraphicsContext.Shading,
        phase: AppState.Phase,
        time: TimeInterval,
        elapsed: TimeInterval
    ) {
        let step = size.width / CGFloat(barCount)
        let barWidth = step * 0.55
        let centerY = size.height / 2

        for (index, height) in heights.enumerated() {
            var x = step * (CGFloat(index) + 0.5) - barWidth / 2
            if isError(phase) {
                // Horizontal glitch displacement.
                let bucket = Int(time * 18)
                x += CGFloat((pseudoRandom(index: index &+ 97, bucket: bucket) - 0.5) * 5)
            }
            let rect = CGRect(x: x, y: centerY - height / 2, width: barWidth, height: height)
            let path = Path(roundedRect: rect, cornerRadius: barWidth / 2)
            context.fill(path, with: shading)
        }
    }

    private func drawScanlines(into context: inout GraphicsContext, size: CGSize) {
        var y: CGFloat = 0
        while y < size.height {
            let rect = CGRect(x: 0, y: y, width: size.width, height: 1)
            context.fill(Path(rect), with: .color(.black.opacity(0.08)))
            y += 4
        }
    }

    // MARK: - Helpers

    private func shimmerBoost(normalizedX: Double, time: TimeInterval) -> Double {
        // Sweeps from slightly off-screen left to off-screen right, looping.
        let position = (time * 0.55).truncatingRemainder(dividingBy: 1.4) - 0.2
        return exp(-pow((normalizedX - position) / 0.09, 2))
    }

    private func pseudoRandom(index: Int, bucket: Int) -> Double {
        var hash = UInt64(bitPattern: Int64(index &* 2654435761 &+ bucket &* 40503))
        hash ^= hash >> 33
        hash = hash &* 0xFF51AFD7ED558CCD
        hash ^= hash >> 33
        return Double(hash % 1000) / 999.0
    }

    private func isError(_ phase: AppState.Phase) -> Bool {
        if case .error = phase { return true }
        return false
    }
}
