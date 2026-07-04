import Foundation

/// Encodes Float32 PCM samples as a 16-bit mono WAV file in memory.
enum WAVEncoder {
    static func encode(samples: [Float], sampleRate: Int = Int(AudioCaptureEngine.targetSampleRate)) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        let byteRate = sampleRate * bytesPerSample

        var data = Data(capacity: 44 + dataSize)
        data.append(contentsOf: Array("RIFF".utf8))
        appendLittleEndian(UInt32(36 + dataSize), to: &data)
        data.append(contentsOf: Array("WAVE".utf8))

        data.append(contentsOf: Array("fmt ".utf8))
        appendLittleEndian(UInt32(16), to: &data)                 // fmt chunk size
        appendLittleEndian(UInt16(1), to: &data)                  // PCM
        appendLittleEndian(UInt16(1), to: &data)                  // mono
        appendLittleEndian(UInt32(sampleRate), to: &data)
        appendLittleEndian(UInt32(byteRate), to: &data)
        appendLittleEndian(UInt16(bytesPerSample), to: &data)     // block align
        appendLittleEndian(UInt16(16), to: &data)                 // bits per sample

        data.append(contentsOf: Array("data".utf8))
        appendLittleEndian(UInt32(dataSize), to: &data)

        for sample in samples {
            let clamped = max(-1, min(1, sample))
            appendLittleEndian(UInt16(bitPattern: Int16(clamped * 32767)), to: &data)
        }
        return data
    }

    private static func appendLittleEndian<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { data.append(contentsOf: $0) }
    }
}
