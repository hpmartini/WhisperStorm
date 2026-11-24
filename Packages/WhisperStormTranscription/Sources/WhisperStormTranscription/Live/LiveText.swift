import Foundation

/// A recognised word; times in seconds from the recording start (same clock as `SpeechChunk.start`).
public struct LiveWord: Equatable, Sendable {
    public let start: TimeInterval
    public let end: TimeInterval
    /// As delivered, including leading blank and punctuation.
    public let text: String

    public init(start: TimeInterval, end: TimeInterval, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }

    var middle: TimeInterval { (start + end) / 2 }
}

/// The text of one live dictation: Whisper results, confirmed live paragraphs not yet replaced, and provisional words.
///
/// A Whisper chunk replaces exactly the live words whose middle lies inside its range, so a live sentence straddling
/// a chunk boundary loses only the replaced half. Live words arriving for an already replaced range are dropped.
/// Empty Whisper text (no speech) clears the range; a failed chunk is never passed here, so its live text stays.
public struct LiveText: Sendable {
    private var whisper: [(start: TimeInterval, text: String)] = []
    private var live: [[LiveWord]] = []
    private var provisional: [LiveWord] = []
    private var replaced: [Range<TimeInterval>] = []

    public init() {}

    /// A final live result: its words become a paragraph, provisional words before `through` are superseded.
    public mutating func confirm(_ words: [LiveWord], through: TimeInterval) {
        provisional.removeAll { $0.start < through }
        let kept = words.filter { !isReplaced($0) && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        if !kept.isEmpty { live.append(kept) }
    }

    /// The latest volatile live result; replaces the previous one.
    public mutating func setProvisional(_ words: [LiveWord]) {
        provisional = words.filter { !isReplaced($0) }
    }

    /// Whisper's text for `range` takes the place of the live words in that range.
    public mutating func replace(_ range: Range<TimeInterval>, with text: String) {
        let text = Self.collapse(text)
        if !text.isEmpty { whisper.append((range.lowerBound, text)) }
        replaced.append(range)
        live = live.compactMap { words in
            let rest = words.filter { !range.contains($0.middle) }
            return rest.isEmpty ? nil : rest
        }
        provisional.removeAll { range.contains($0.middle) }
    }

    /// Never contains "\n": it gets typed into terminals and chats where Return submits.
    public var confirmedText: String {
        let paragraphs = whisper + live.map { ($0[0].start, Self.join($0)) }
        return paragraphs
            .filter { Self.isSpeech($0.text) }
            .enumerated()
            .sorted { ($0.element.start, $0.offset) < ($1.element.start, $1.offset) }
            .map(\.element.text)
            .joined(separator: " ")
    }

    public var provisionalText: String {
        let text = Self.join(provisional)
        return Self.isSpeech(text) ? text : ""
    }

    private func isReplaced(_ word: LiveWord) -> Bool {
        replaced.contains { $0.contains(word.middle) }
    }

    static func isSpeech(_ text: String) -> Bool {
        text.unicodeScalars.contains { CharacterSet.alphanumerics.contains($0) }
    }

    /// Joined as delivered; a sentence mark that belongs to the previous result (". Ja sehr schön") is dropped.
    static func join(_ words: [LiveWord]) -> String {
        let text = collapse(words.map(\.text).joined())
        return String(text.drop { ".,;:!?".contains($0) || $0 == " " })
    }

    static func collapse(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
    }
}
