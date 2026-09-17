import Foundation

/// Orders glossary terms by how much they help, and reports what the transcriber can carry.
///
/// whisper.cpp accepts only about 224 prompt tokens, which is roughly 480 characters of
/// glossary text. A working glossary is much larger than that, so the order decides which
/// terms reach the model.
public enum GlossaryUsage {
    /// Terms ordered by recent use, then alphabetically so the order never jumps around.
    /// `usageCounts` is keyed by the lowercased ``GlossaryTerm/preferred`` spelling.
    public static func ranked(
        _ terms: [GlossaryTerm],
        usageCounts: [String: Int]
    ) -> [GlossaryTerm] {
        terms.sorted { left, right in
            let leftCount = usageCounts[left.preferred.lowercased()] ?? 0
            let rightCount = usageCounts[right.preferred.lowercased()] ?? 0
            if leftCount != rightCount { return leftCount > rightCount }
            return left.preferred.lowercased() < right.preferred.lowercased()
        }
    }

    /// Terms that spell a participant name. A misheard name is the most visible error in a
    /// meeting transcript, so these terms outrank everything else in the prompt.
    public static func namingParticipants(
        _ terms: [GlossaryTerm],
        participants: [Participant]
    ) -> [GlossaryTerm] {
        let names = Set(participants.map { $0.name.lowercased() })
        let nameWords = Set(
            participants.flatMap { $0.name.lowercased().split(separator: " ").map(String.init) }
        )
        return terms.filter { term in
            ([term.preferred.lowercased()] + term.aliases.map { $0.lowercased() }).contains { spelling in
                names.contains(spelling) || nameWords.contains(spelling)
            }
        }
    }
}
