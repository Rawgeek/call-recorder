import CryptoKit
import Foundation

/// Rewrites the spellings Whisper got wrong, using the glossary the user already maintains.
///
/// The glossary reached the model as prompt context, and nothing else. A term the user added
/// changed how future audio was decoded, but the text already on disk kept whatever the model
/// produced. The Vocabulary pane told the user that an out-of-budget term "will be applied when
/// a transcript is corrected", and no correction existed, so the promise had nothing behind it.
///
/// The cost of that gap is not cosmetic. Across the stored library a company name appears as
/// "Globexx" and never as "Globex", so a keyword search for the real name returns nothing
/// while reporting success. Correcting the text before it is written fixes the saved file, the
/// search index, and every later reading of the same call at once.
///
/// Build a ``Matcher`` once and reuse it. A transcript holds thousands of segments, and
/// compiling the rules for every one of them dominated the repair that walks the whole library.
public enum GlossaryCorrector {
    /// What a correction pass changed.
    public struct Outcome: Equatable, Sendable {
        public let text: String
        /// How many separate words were rewritten, per preferred spelling.
        public let counts: [String: Int]

        public var replacementCount: Int { counts.values.reduce(0, +) }
        public var didChange: Bool { replacementCount > 0 }

        public init(text: String, counts: [String: Int]) {
            self.text = text
            self.counts = counts
        }
    }

    /// One spelling the user wants replaced, resolved against a preferred term.
    fileprivate struct Rule {
        let alias: String
        let preferred: String
    }

    /// A glossary prepared for repeated use.
    public struct Matcher: Sendable {
        private let rules: [Rule]
        private let byFoldedAlias: [String: String]
        private let aliasExpression: NSRegularExpression?
        private let settledExpression: NSRegularExpression?

        fileprivate init(
            rules: [Rule],
            byFoldedAlias: [String: String],
            aliasExpression: NSRegularExpression?,
            settledExpression: NSRegularExpression?
        ) {
            self.rules = rules
            self.byFoldedAlias = byFoldedAlias
            self.aliasExpression = aliasExpression
            self.settledExpression = settledExpression
        }

        /// True when the glossary has nothing that could change a spelling.
        public var isEmpty: Bool { rules.isEmpty }

        /// Whether the glossary already names a term in this text.
        ///
        /// Used as the context test for a spelling the glossary does not know: a word that merely
        /// sounds like a term is only worth correcting where the call is talking about the term.
        public func mentionsTerm(_ text: String) -> Bool {
            guard !text.isEmpty else { return false }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            if aliasExpression?.firstMatch(in: text, options: [], range: range) != nil { return true }
            return settledExpression?.firstMatch(in: text, options: [], range: range) != nil
        }

        /// Rewrites every known alias in the text into its preferred spelling.
        ///
        /// Matching is case-insensitive and bounded by word edges, so "Globe X" is replaced
        /// as a phrase and "Sam" is not replaced inside "Samson". Longer aliases are tried
        /// first, which keeps "Globe X" from being half-replaced by a shorter overlapping
        /// rule.
        public func correct(_ text: String) -> Outcome {
            // Correcting one spelling can expose another: collapsing "Meridien Line" to "Meridian"
            // can complete a phrase that a further rule matches. Repeating until the text stops
            // changing makes one pass enough, so the button in Recovery finishes its work in one
            // click instead of needing a second run. The bound is a guard against a long chain,
            // not an expected limit: every rule settles the spelling it rewrites, so the text can
            // only change a bounded number of times.
            var running = text
            var totals: [String: Int] = [:]
            for _ in 0..<8 {
                let step = correctOnce(running)
                guard step.didChange else { break }
                running = step.text
                for (preferred, count) in step.counts {
                    totals[preferred, default: 0] += count
                }
            }
            return Outcome(text: running, counts: totals)
        }

        /// One pass over the text.
        private func correctOnce(_ text: String) -> Outcome {
            guard !text.isEmpty, let expression = aliasExpression else {
                return Outcome(text: text, counts: [:])
            }
            let fullRange = NSRange(text.startIndex..<text.endIndex, in: text)

            // Spans that already read the way the user saved them are settled, so nothing may
            // rewrite inside them. Without this a short form expands into the full name that
            // contains it and the next pass expands it again: "Ani" inside "Andrew Ani" grew
            // the line on every run.
            let settled = settledRanges(in: text)
            let matches = expression.matches(in: text, options: [], range: fullRange)
                // Only a match that sits inside a settled span is skipped. A match that merely
                // overlaps one is a longer alternative being normalised: "Meridian Line"
                // contains "Meridian" and must still become "Meridian", while "Sam" inside a
                // settled "Sammy Lee" must not expand again.
                .filter { match in
                    !settled.contains { span in
                        match.range.location >= span.location
                            && NSMaxRange(match.range) <= NSMaxRange(span)
                    }
                }
            guard !matches.isEmpty else { return Outcome(text: text, counts: [:]) }

            var counts: [String: Int] = [:]
            var corrected = ""
            corrected.reserveCapacity(text.count)
            var cursor = text.startIndex
            for match in matches {
                guard let range = Range(match.range, in: text) else { continue }
                let found = String(text[range])
                let preferred = byFoldedAlias[GlossaryCorrector.folded(found)] ?? found
                corrected.append(contentsOf: text[cursor..<range.lowerBound])
                corrected.append(contentsOf: preferred)
                cursor = range.upperBound
                counts[preferred, default: 0] += 1
            }
            corrected.append(contentsOf: text[cursor...])
            return Outcome(text: corrected, counts: counts)
        }

        /// The ranges of the text that already read the way the user saved them.
        private func settledRanges(in text: String) -> [NSRange] {
            guard let settledExpression else { return [] }
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return settledExpression.matches(in: text, options: [], range: range).map(\.range)
        }
    }

    /// Prepares a glossary for repeated use.
    public static func matcher(for terms: [GlossaryTerm]) -> Matcher {
        let rules = self.rules(from: terms)
        let preferreds = preferredSpellings(from: terms)
        let byFoldedAlias = Dictionary(
            rules.map { (folded($0.alias), $0.preferred) },
            // A later term must not silently win; the first declared spelling is the one kept.
            uniquingKeysWith: { first, _ in first }
        )
        return Matcher(
            rules: rules,
            byFoldedAlias: byFoldedAlias,
            aliasExpression: expression(
                for: rules.map { NSRegularExpression.escapedPattern(for: $0.alias) }
            ),
            settledExpression: expression(
                for: preferreds.map { NSRegularExpression.escapedPattern(for: $0) }
            )
        )
    }

    /// Rewrites every known alias in the text. Prefer a ``Matcher`` for more than one text.
    public static func correct(_ text: String, terms: [GlossaryTerm]) -> Outcome {
        matcher(for: terms).correct(text)
    }

    /// A stable value for the repair rules the glossary currently holds.
    ///
    /// Rewriting every saved transcript is not something to do on a guess, and the app has no way
    /// to know a term was added unless it is told. Comparing this value against the one recorded
    /// when the library was last repaired is what tells the app the work is owed: same rules,
    /// nothing to do, and no pass over the files.
    ///
    /// The rules rather than the terms. A term whose alias list did not change cannot change any
    /// text, and neither can an alias that merely restates its own preferred spelling, which
    /// ``rules(from:)`` already drops. A glossary edit that adds no rule leaves this value alone.
    public static func fingerprint(of terms: [GlossaryTerm]) -> String {
        let pairs = rules(from: terms)
            .map { folded($0.alias) + ">" + folded($0.preferred) }
            .sorted()
        var hasher = SHA256()
        for pair in pairs {
            hasher.update(data: Data(pair.utf8))
            // A separator, so two adjacent rules cannot spell a third one's text.
            hasher.update(data: Data([0x0a]))
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Every alias that would actually change something.
    ///
    /// An alias equal to its own preferred spelling is dropped: it would match, replace
    /// itself, and report a correction that never happened.
    private static func rules(from terms: [GlossaryTerm]) -> [Rule] {
        var seen = Set<String>()
        var rules: [Rule] = []
        for term in terms {
            let preferred = term.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !preferred.isEmpty else { continue }
            let foldedPreferred = folded(preferred)
            for rawAlias in term.aliases {
                let alias = rawAlias.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !alias.isEmpty else { continue }
                let foldedAlias = folded(alias)
                guard foldedAlias != foldedPreferred else { continue }
                guard seen.insert(foldedAlias).inserted else { continue }
                rules.append(Rule(alias: alias, preferred: preferred))
            }
        }
        // Longest first: an alternation is tried left to right, so the longest phrase has to
        // come before any shorter phrase that starts the same way.
        return rules.sorted { $0.alias.count > $1.alias.count }
    }

    /// The spellings the user saved as correct, longest first so a full name wins over a short
    /// one.
    private static func preferredSpellings(from terms: [GlossaryTerm]) -> [String] {
        var seen = Set<String>()
        var preferreds: [String] = []
        for term in terms {
            let preferred = term.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !preferred.isEmpty, seen.insert(folded(preferred)).inserted else { continue }
            preferreds.append(preferred)
        }
        return preferreds.sorted { $0.count > $1.count }
    }

    private static func expression(for alternatives: [String]) -> NSRegularExpression? {
        guard !alternatives.isEmpty else { return nil }
        return try? NSRegularExpression(pattern: edge(alternatives), options: [.caseInsensitive])
    }

    /// One alternation, bounded on both sides so a term is never matched inside a longer word.
    ///
    /// A word-boundary escape is wrong for a term that starts or ends with a non-word
    /// character, so the edges are stated directly as "not a letter or digit". Alternatives
    /// must arrive longest first, because an alternation is tried left to right.
    private static func edge(_ alternatives: [String]) -> String {
        let letter = "\\p{L}"
        let number = "\\p{N}"
        return "(?<![\(letter)\(number)])(?:" + alternatives.joined(separator: "|")
            + ")(?![\(letter)\(number)])"
    }

    private static func folded(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
    }
}

// MARK: - The spellings the model invented for a declared term

extension GlossaryCorrector {
    /// A spelling a decoder invented for a term the glossary already declares.
    public struct Suggestion: Equatable, Sendable {
        /// What the model wrote, as the call first writes it.
        public let found: String
        /// The spelling the user saved.
        public let preferred: String
        /// How many times the invented spelling appears in the call.
        public let count: Int

        public init(found: String, preferred: String, count: Int) {
            self.found = found
            self.preferred = preferred
            self.count = count
        }
    }

    /// How many times a word may appear in a call and still be read as a misheard term.
    ///
    /// Four. A decoder writing a name it does not know uses the same wrong spelling each time, and
    /// a call has the term in a handful of places. A word the call uses over and over is the call's
    /// own vocabulary, and rewriting it would be rewriting the language of the meeting.
    public static let suggestedAliasMaximumOccurrences = 4

    /// The shortest word that can be read as a misheard term.
    ///
    /// Four characters. Three-letter words sound like far too much of the language to correct on
    /// their own: "сто" is one edit from the key of "Salla", and it is also the Russian word for a
    /// hundred. The library's real cases -- "салют", "биспер", "Роза", "Айрхаус" -- are all longer.
    public static let suggestedAliasMinimumCharacters = 4

    /// Rewrites the spellings the model invented for terms the user declared, using sound and
    /// context.
    ///
    /// The glossary reached the model as prompt context, and the correction pass rewrote only the
    /// aliases that were declared, so a term the user added changed nothing about text already on
    /// disk. The 2026-09-18 call is what that costs: the glossary names Salla, DeepSeek, Whisper,
    /// Rasa, Airhouse and CartRover, and the body says "салют", "DeepSecret", "биспер", "Роза",
    /// "Айрхаус" and "карт-ровер". Not one of those is a declared alias, and every one is the term
    /// as the decoder heard it.
    ///
    /// Three rules keep ordinary speech out of it:
    ///
    /// - **Sound or letters, never both loosely.** The invented spelling either has the same
    ///   phonetic key as a declared spelling of the term, or it is a few letters away from it.
    ///   "биспер" and "Whisper" share a key; "салют" and "Salla" share letters. A word that is one
    ///   edit from a key and nowhere near it by letters -- "работает" against "Airhouse" -- is not a
    ///   match, which is what keeps the language of the meeting out of it.
    /// - **Context.** The word is corrected only on a line that already holds a term the glossary
    ///   matches, or whose line before it does. A word that merely sounds like a name is corrected
    ///   where the call is talking about the world that name belongs to.
    /// - **Rarity.** The invented spelling may not appear more than four times in the call, and it
    ///   may not be resolvable to two different terms.
    public static func applyingSuggestedAliases(
        _ text: String,
        terms: [GlossaryTerm]
    ) -> (text: String, suggestions: [Suggestion]) {
        let found = suggestedAliases(in: text, terms: terms)
        guard !found.isEmpty else { return (text, []) }
        var corrected = text
        // Longest first, so a longer invented phrase is replaced before a shorter one that starts
        // the same way can cut into it.
        for suggestion in found.sorted(by: { $0.found.count > $1.found.count }) {
            corrected = replacing(suggestion.found, with: suggestion.preferred, in: corrected)
        }
        return (corrected, found)
    }

    /// The suggestions alone, for a caller that reports them rather than rewriting the text.
    public static func suggestedAliases(in text: String, terms: [GlossaryTerm]) -> [Suggestion] {
        guard !text.isEmpty, !terms.isEmpty else { return [] }
        let matcher = matcher(for: terms)
        var declared = Set<String>()
        var keyed: [(preferred: String, latin: String, key: String)] = []
        for term in terms {
            let preferred = term.preferred.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !preferred.isEmpty else { continue }
            for spelling in [preferred] + term.aliases {
                let trimmed = spelling.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                declared.insert(folded(trimmed))
                if let key = phoneticKey(trimmed) {
                    keyed.append((preferred, latinSpelling(trimmed), key))
                }
            }
        }
        guard !keyed.isEmpty else { return [] }

        // Every word of the call, how often it appears and how it is written the first time. A
        // misheard name is rare and consistent; an ordinary word is neither.
        var appearances: [String: (spelling: String, count: Int)] = [:]
        for word in words(in: text) {
            let foldedWord = folded(word)
            guard !foldedWord.isEmpty else { continue }
            if var entry = appearances[foldedWord] {
                entry.count += 1
                appearances[foldedWord] = entry
            } else {
                appearances[foldedWord] = (word, 1)
            }
        }

        var found: [String: Suggestion] = [:]
        var ambiguous = Set<String>()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        for (index, line) in lines.enumerated() {
            // The line and the one before it. A sentence is often split across two whisper segments,
            // and a person reading the transcript has the line above in view when they decide what a
            // word is.
            let context = index > 0 ? lines[index - 1] + "\n" + line : line
            guard matcher.mentionsTerm(context) else { continue }
            for word in words(in: line) {
                let foldedWord = folded(word)
                guard !declared.contains(foldedWord) else { continue }
                guard foldedWord.count >= suggestedAliasMinimumCharacters else { continue }
                guard let entry = appearances[foldedWord],
                    entry.count <= suggestedAliasMaximumOccurrences
                else { continue }
                // Two readings of "the same word": the letters nearly match, or the sounds match
                // exactly. The letters catch "салют" for Salla and "Роза" for Rasa, where the
                // decoder wrote a word of its own language that is spelled like the name. The
                // sounds catch "биспер" for Whisper, where it wrote the letters its language uses
                // for a w. Neither reading is allowed to be fuzzy on both axes at once, which is
                // what keeps "работает" and "быстрее" out: each is one sound away from a term and
                // nowhere near it by letters.
                let letters = latinSpelling(word)
                var letterMatches: [(preferred: String, distance: Int)] = []
                var soundMatches: [String] = []
                for candidate in keyed {
                    let distance = phoneticDistance(letters, candidate.latin)
                    if distance <= letterAllowance(letters, candidate.latin) {
                        letterMatches.append((candidate.preferred, distance))
                    }
                    if let key = phoneticKey(word), key == candidate.key, key.count >= 3 {
                        soundMatches.append(candidate.preferred)
                    }
                }
                let closestLetters = letterMatches.map(\.distance).min()
                let letterWinners = Set(
                    letterMatches.filter { $0.distance == closestLetters }.map(\.preferred)
                )
                let winners = letterWinners.isEmpty ? Set(soundMatches) : letterWinners
                guard winners.count == 1, let preferred = winners.first else {
                    if winners.count > 1 { ambiguous.insert(foldedWord) }
                    continue
                }
                if let previous = found[foldedWord], previous.preferred != preferred {
                    ambiguous.insert(foldedWord)
                } else {
                    found[foldedWord] = Suggestion(
                        found: entry.spelling,
                        preferred: preferred,
                        count: entry.count
                    )
                }
            }
        }
        for foldedWord in ambiguous { found.removeValue(forKey: foldedWord) }
        return found.values.sorted { $0.found.lowercased() < $1.found.lowercased() }
    }

    /// The words of a text, with a hyphen kept inside one so "карт-ровер" is a single word.
    static func words(in text: String) -> [String] {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return wordPattern.matches(in: text, options: [], range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: text) else { return nil }
            return String(text[matchRange]).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        }
    }

    private static let wordPattern = try! NSRegularExpression(
        pattern: "[\\p{L}\\p{N}][\\p{L}\\p{N}\\-]*"
    )

    /// Replaces every whole-word occurrence of one spelling with another.
    static func replacing(_ alias: String, with preferred: String, in text: String) -> String {
        guard let expression = expression(for: [NSRegularExpression.escapedPattern(for: alias)]) else {
            return text
        }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(
            in: text,
            options: [],
            range: range,
            withTemplate: NSRegularExpression.escapedTemplate(for: preferred)
        )
    }

    /// The sound of a word, written so two spellings of it can be compared.
    ///
    /// The word is transliterated into Latin letters, the vowels and the doubled letters are
    /// dropped, and the consonants are folded into classes a speaker of either language does not
    /// hear as different. "биспер" becomes "fsfr" and "Whisper" becomes "fsfr"; "салют" becomes
    /// "slt" against the "sl" of "Salla". Two spellings of one word land on the same key, whatever
    /// alphabet the decoder wrote them in.
    static func phoneticKey(_ word: String) -> String? {
        var key = ""
        for character in latinSpelling(word) {
            guard let sound = soundClass(character) else { continue }
            if key.last == sound { continue }
            key.append(sound)
        }
        return key.isEmpty ? nil : key
    }

    /// The Latin letters a character stands for, by sound rather than by alphabet.
    private static func latinLetters(for character: Character) -> String {
        switch character {
        case "а": "a"
        case "б": "b"
        case "в": "v"
        case "г": "g"
        case "д": "d"
        case "е", "ё", "э": "e"
        case "ж": "zh"
        case "з": "z"
        case "и", "й", "ы", "і": "i"
        case "к": "k"
        case "л": "l"
        case "м": "m"
        case "н": "n"
        case "о": "o"
        case "п": "p"
        case "р": "r"
        case "с": "s"
        case "т": "t"
        case "у": "u"
        case "ф": "f"
        case "х": "h"
        case "ц": "ts"
        case "ч": "ch"
        case "ш", "щ": "sh"
        case "ю": "iu"
        case "я": "ia"
        case "ъ", "ь": ""
        default:
            character.isLetter || character.isNumber ? String(character) : ""
        }
    }

    /// The class a consonant belongs to, or nil for a sound that is not written down.
    private static func soundClass(_ character: Character) -> Character? {
        switch character {
        case "a", "e", "i", "o", "u", "y": nil
        // A labial heard as its partner: "биспер" for "Whisper" turns on exactly this. The letter h
        // travels with them because a transliterated h is usually the same puff of air.
        case "b", "p", "f", "v", "w", "h": "f"
        case "c", "k", "q", "g": "k"
        case "s", "z", "x", "j": "s"
        case "d", "t": "t"
        case "l": "l"
        case "m": "m"
        case "n": "n"
        case "r": "r"
        default: nil
        }
    }

    /// How far two spellings may differ and still be one word, by letters.
    ///
    /// One edit for a short word, two for one of four or five letters, three for a longer one. The
    /// window grows with the word because a longer word has more places for a decoder to slip, and
    /// because a three-edit window on a four-letter word would reach half the language.
    static func letterAllowance(_ left: String, _ right: String) -> Int {
        let longest = max(left.count, right.count)
        if longest <= 3 { return 1 }
        return longest <= 5 ? 2 : 3
    }

    /// A spelling written in Latin letters and nothing else.
    ///
    /// Both sides of a comparison are put in one alphabet before they are compared, so a name the
    /// decoder wrote in Cyrillic and the name the user saved in Latin are measured as the same word.
    static func latinSpelling(_ word: String) -> String {
        var latin = ""
        for character in word.lowercased() {
            latin += latinLetters(for: character)
        }
        return latin.filter { $0.isLetter || $0.isNumber }
    }

    /// The number of single-character edits that turn one key into the other.
    static func phoneticDistance(_ left: String, _ right: String) -> Int {
        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        if leftCharacters.isEmpty { return rightCharacters.count }
        if rightCharacters.isEmpty { return leftCharacters.count }
        var previous = Array(0...rightCharacters.count)
        var current = [Int](repeating: 0, count: rightCharacters.count + 1)
        for (leftIndex, leftCharacter) in leftCharacters.enumerated() {
            current[0] = leftIndex + 1
            for (rightIndex, rightCharacter) in rightCharacters.enumerated() {
                let substitution = previous[rightIndex] + (leftCharacter == rightCharacter ? 0 : 1)
                current[rightIndex + 1] = min(
                    previous[rightIndex + 1] + 1,
                    current[rightIndex] + 1,
                    substitution
                )
            }
            previous = current
        }
        return previous[rightCharacters.count]
    }
}
