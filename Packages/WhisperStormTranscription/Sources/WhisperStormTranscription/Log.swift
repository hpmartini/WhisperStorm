import os

// Same subsystem/category as the app so existing `log stream` filters keep working.
enum Log {
    static let transcription = Logger(subsystem: "de.martinilabs.WhisperStorm", category: "transcription")
}
