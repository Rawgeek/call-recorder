import Foundation

/// Names the language a transcript was read in.
///
/// The reader answers with the language it detected, and that answer is not always a code: the
/// script this app reads with reports the language it decided on, and an older one reported none at
/// all. The transcript still has to name a language: the header prints it, and later stages of the
/// pipeline read it. A language the setting named is the answer; when the setting asks the model,
/// the code it answered is used, and the script the words are written in is the fallback.
public enum TranscriptLanguage {
    /// The answers the app writes when no language has been chosen.
    public static func asksTheModel(_ language: String) -> Bool {
        let code = language.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return code.isEmpty || code == "auto" || code == "unknown"
    }

    /// The language a transcript names.
    public static func naming(requested: String, text: String) -> String {
        if !asksTheModel(requested) {
            return String(requested.trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased().prefix(2))
        }
        let cyrillic = text.unicodeScalars.contains { (0x0400...0x04FF).contains($0.value) }
        return cyrillic ? "ru" : "en"
    }
}
