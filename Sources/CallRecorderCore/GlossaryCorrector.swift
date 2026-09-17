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
