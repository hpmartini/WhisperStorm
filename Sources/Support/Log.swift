import os

enum Log {
    static let app = Logger(subsystem: "de.martinilabs.WhisperStorm", category: "app")
    static let audio = Logger(subsystem: "de.martinilabs.WhisperStorm", category: "audio")
    static let transcription = Logger(subsystem: "de.martinilabs.WhisperStorm", category: "transcription")
    static let insertion = Logger(subsystem: "de.martinilabs.WhisperStorm", category: "insertion")
    static let overlay = Logger(subsystem: "de.martinilabs.WhisperStorm", category: "overlay")
}
