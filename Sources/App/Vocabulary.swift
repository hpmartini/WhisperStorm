import Foundation

/// The user's domain vocabulary, edited in the Vocabulary window or directly in
/// `~/Library/Application Support/WhisperStorm/vocabulary.txt`; read fresh for
/// every transcription, so changes need no restart.
///
/// One entry per line:
/// - `Term`: spelled as it should appear; goes into Whisper's prompt.
/// - `wrong → right` (or `->`): after the run, `wrong` (whole word, any case)
///   becomes `right`; `right` also goes into the prompt.
/// - `# …` comments and blank lines are ignored.
struct Vocabulary: Equatable {
    struct Replacement: Equatable {
        let wrong: String
        let right: String
    }

    /// Whisper's prompt holds at most 224 tokens; a short glossary keeps the
    /// audio in charge (long prompts make Whisper repeat the prompt).
    static let maxPromptCharacters = 400

    static let defaultText = """
    # WhisperStorm vocabulary: one term per line, or "wrong → right" for a fixed replacement.
    # Terms go into Whisper's prompt; replacements run after each transcription. Saved changes apply to the next dictation.
    DATEV
    ADDISON
    Belegfreigabe
    Mandant
    Umsatzsteuervoranmeldung
    Done-Kriterien
    Dann-Kriterien → Done-Kriterien
    Orkumo
    MAGOS
    TapeStorm
    WhisperStorm
    Codex
    Claude

    """

    static var fileURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/WhisperStorm/vocabulary.txt")
    }

    private(set) var terms: [String] = []
    private(set) var replacements: [Replacement] = []

    init(text: String) {
        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.components(separatedBy: "→").count == 2
                ? line.components(separatedBy: "→")
                : line.components(separatedBy: "->")
            if parts.count == 2 {
                let wrong = parts[0].trimmingCharacters(in: .whitespaces)
                let right = parts[1].trimmingCharacters(in: .whitespaces)
                guard !wrong.isEmpty, !right.isEmpty else { continue }
                replacements.append(Replacement(wrong: wrong, right: right))
                addTerm(right)
            } else {
                addTerm(line)
            }
        }
    }

    /// The vocabulary file; written with the default list on first use.
    static func load(from url: URL = fileURL) -> Vocabulary {
        if let text = try? String(contentsOf: url, encoding: .utf8) {
            return Vocabulary(text: text)
        }
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? defaultText.write(to: url, atomically: true, encoding: .utf8)
        return Vocabulary(text: defaultText)
    }

    /// "Glossar: A, B, C." — earlier lines first, cut at whole terms.
    var prompt: String? {
        var listed: [String] = []
        for term in terms {
            let candidate = "Glossar: " + (listed + [term]).joined(separator: ", ") + "."
            guard candidate.count <= Self.maxPromptCharacters else { break }
            listed.append(term)
        }
        return listed.isEmpty ? nil : "Glossar: " + listed.joined(separator: ", ") + "."
    }

    /// Replacements first, then the spelling of acronym and CamelCase terms
    /// ("Addison" → "ADDISON"). Terms that are ordinary words ("Mandant",
    /// "Done") keep whatever case Whisper chose.
    func apply(to text: String) -> String {
        var result = text
        for replacement in replacements {
            result = Self.replaceWholeWord(replacement.wrong, with: replacement.right, in: result)
        }
        for term in terms where term.filter(\.isUppercase).count >= 2 {
            result = Self.replaceWholeWord(term, with: term, in: result)
        }
        return result
    }

    private mutating func addTerm(_ term: String) {
        if !terms.contains(term) { terms.append(term) }
    }

    private static func replaceWholeWord(_ word: String, with replacement: String, in text: String) -> String {
        let pattern = #"(?<![\p{L}\p{N}])"# + NSRegularExpression.escapedPattern(for: word) + #"(?![\p{L}\p{N}])"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return text }
        let range = NSRange(text.startIndex..., in: text)
        return regex.stringByReplacingMatches(
            in: text, range: range, withTemplate: NSRegularExpression.escapedTemplate(for: replacement)
        )
    }
}
