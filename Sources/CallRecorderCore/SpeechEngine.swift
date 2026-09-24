import Foundation

/// Which engine turns a recording into words.
///
/// The app carries two. Parakeet runs on the Neural Engine and reads the languages of the calls
/// this app records; whisper.cpp reads every language the app may meet, and is what runs when
/// Parakeet has nothing to say about the language in front of it. The choice is a setting, and the
/// rules that turn the setting into an answer live here, where they can be read and tested without
/// a 600 MB model on disk.
public enum SpeechEngine: String, Codable, Sendable, CaseIterable, Identifiable {
    case parakeet
    case whisper

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .parakeet: return "Parakeet"
        case .whisper: return "whisper.cpp"
        }
    }
}

/// What each engine can read, and which one will answer a call.
public enum SpeechEngineChoice {
    /// The languages Parakeet TDT 0.6B v3 is trained for, taken from its model card: twenty-five
    /// European languages, Russian and Ukrainian among them, with automatic language detection.
    public static let parakeetLanguages: Set<String> = [
        "bg", "cs", "da", "de", "el", "en", "es", "et", "fi", "fr", "hr", "hu", "it", "lt",
        "lv", "mt", "nl", "pl", "pt", "ro", "ru", "sk", "sl", "sv", "uk",
    ]

    /// The answers the app writes when no language has been chosen.
    public static func asksTheModel(_ language: String) -> Bool {
        let code = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return code.isEmpty || code == "auto" || code == "unknown"
    }

    /// Whether Parakeet is trained for this language.
    ///
    /// A language nobody named is its own answer: the model detects the language as it decodes, which
    /// is the same bargain whisper.cpp offers with the word auto, and both engines answer it.
    public static func parakeetReads(_ language: String) -> Bool {
        if asksTheModel(language) { return true }
        let code = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return parakeetLanguages.contains(String(code.prefix(2)))
    }

    /// The engine that will answer this call.
    ///
    /// - Parameters:
    ///   - requested: What the user chose.
    ///   - language: The language the call is in, or the word the app writes when it is not known.
    ///   - parakeetIsReady: Whether the Parakeet model is on disk. A setting that cannot be
    ///     honoured falls back to whisper rather than failing the call: the words matter more than
    ///     the engine that found them.
    public static func engine(
        requested: SpeechEngine,
        language: String,
        parakeetIsReady: Bool
    ) -> SpeechEngine {
        guard requested == .parakeet, parakeetIsReady else { return .whisper }
        return parakeetReads(language) ? .parakeet : .whisper
    }

    /// The language a Parakeet transcript names.
    ///
    /// Parakeet reads the language as it decodes and reports no code for it, where whisper.cpp
    /// answers with the one it decided on. The transcript still has to name a language: the brief
    /// is written in it, and the header prints it. A language the setting named is the answer.
    /// When the setting asks the model, the script the words are written in tells the two
    /// languages this app records apart, and anything that is not Cyrillic is read as English.
    public static func transcriptLanguage(requested: String, text: String) -> String {
        if !asksTheModel(requested) {
            return String(requested.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().prefix(2))
        }
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return cyrillic ? "ru" : "en"
    }
}
