import Foundation

/// Appends diagnostic lines to ~/Library/Logs/WhisperStorm.log.
///
/// The unified log (os.Logger) proved unreliable to read back for this app
/// during development, so insertion diagnostics also go to a plain file the
/// user can open and share. Best-effort: failures here are swallowed.
enum FileLog {
    private static let queue = DispatchQueue(label: "de.martinilabs.WhisperStorm.filelog")

    static let url: URL = {
        let dir = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
            .appending(path: "Logs")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "WhisperStorm.log")
    }()

    static func write(_ message: String) {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        let line = "\(timestamp) \(message)\n"
        queue.async {
            guard let data = line.data(using: .utf8) else { return }
            if let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
            } else {
                try? data.write(to: url, options: .atomic)
            }
        }
    }
}
