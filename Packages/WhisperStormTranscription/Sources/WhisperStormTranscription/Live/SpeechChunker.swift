import Foundation

/// A piece of the recording handed to Whisper.
public struct SpeechChunk: Equatable, Sendable {
    /// Seconds from the recording start.
    public let start: TimeInterval
    /// 16 kHz mono.
    public let samples: [Float]

    public init(start: TimeInterval, samples: [Float]) {
        self.start = start
        self.samples = samples
    }

    public var duration: TimeInterval { Double(samples.count) / SpeechChunker.sampleRate }
    public var range: Range<TimeInterval> { start..<start + duration }
}

/// Cuts a 16 kHz mono stream into chunks at speech pauses, at the latest after `maxDuration`.
/// Holds at most one chunk in memory, so a long dictation costs no more than a short one.
public struct SpeechChunker {
    public static let sampleRate: Double = 16_000
    static let frame = 320  // 20 ms

    public var maxDuration: TimeInterval = 30
    public var minDuration: TimeInterval = 3
    public var pauseDuration: TimeInterval = 0.6
    /// Frames louder than this count as speech (mic noise floor around −53 dBFS, speech around −30).
    public var speechThresholdDB: Float = -42

    private var buffer: [Float] = []
    private var bufferStart = 0  // sample index of buffer[0] since recording start
    private var pending: [Float] = []  // samples not yet forming a whole frame
    private var silentFrames = 0
    private var hasSpeech = false

    public init() {}

    /// Feeds samples and returns the chunks completed by them.
    public mutating func append(_ samples: [Float]) -> [SpeechChunk] {
        pending.append(contentsOf: samples)
        var out: [SpeechChunk] = []
        var i = 0
        while pending.count - i >= Self.frame {
            let f = pending[i..<i + Self.frame]
            i += Self.frame
            buffer.append(contentsOf: f)
            if Self.dB(f) > speechThresholdDB {
                hasSpeech = true
                silentFrames = 0
            } else {
                silentFrames += 1
            }
            let length = Double(buffer.count) / Self.sampleRate
            let pause = Double(silentFrames * Self.frame) / Self.sampleRate
            if !hasSpeech {
                // Whisper hallucinates on leading silence; keep only a short lead-in.
                let keep = Int(0.3 * Self.sampleRate)
                if buffer.count > Int(Self.sampleRate) {
                    let drop = buffer.count - keep
                    buffer.removeFirst(drop)
                    bufferStart += drop
                }
            } else if length >= maxDuration || (length >= minDuration && pause >= pauseDuration) {
                out.append(cut())
            }
        }
        pending.removeFirst(i)
        return out
    }

    /// Returns the rest as a final chunk, or nil when it holds no speech.
    public mutating func flush() -> SpeechChunk? {
        buffer.append(contentsOf: pending)
        pending = []
        if !hasSpeech && !buffer.contains(where: { abs($0) > Self.amplitude(speechThresholdDB) }) {
            bufferStart += buffer.count
            buffer = []
            return nil
        }
        return buffer.isEmpty ? nil : cut()
    }

    private mutating func cut() -> SpeechChunk {
        let chunk = SpeechChunk(start: Double(bufferStart) / Self.sampleRate, samples: buffer)
        bufferStart += buffer.count
        buffer = []
        silentFrames = 0
        hasSpeech = false
        return chunk
    }

    static func dB<C: Collection>(_ s: C) -> Float where C.Element == Float {
        guard !s.isEmpty else { return -120 }
        let sum = s.reduce(Float(0)) { $0 + $1 * $1 }
        let rms = (sum / Float(s.count)).squareRoot()
        return rms <= 1e-9 ? -120 : 20 * log10(rms)
    }

    static func amplitude(_ dB: Float) -> Float { pow(10, dB / 20) }
}
