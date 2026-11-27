import Foundation

/// One word of the script, with where it sits in the text.
struct ScriptWord {
    /// Lowercased, without punctuation or accents, for matching against speech.
    let key: String
    /// Range of the word in the script, as UTF-16 offsets (for TextKit).
    let range: NSRange
    /// Start of the word in the script string.
    let start: String.Index
}

enum ScriptWords {
    /// Splits text into words the same way for the script and for what was heard.
    static func tokenize(_ text: String) -> [ScriptWord] {
        var words: [ScriptWord] = []
        text.enumerateSubstrings(in: text.startIndex..<text.endIndex, options: [.byWords, .localized]) { word, range, _, _ in
            guard let word else { return }
            let key = normalize(word)
            guard !key.isEmpty else { return }
            words.append(ScriptWord(key: key, range: NSRange(range, in: text), start: range.lowerBound))
        }
        return words
    }

    static func keys(_ text: String) -> [String] { tokenize(text).map(\.key) }

    static func normalize(_ word: String) -> String {
        let folded = word.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }
}

/// Follows a speaker through the script by matching the last few words heard
/// against the words just ahead of where they are.
///
/// Pure logic with no audio, so it is easy to reason about and test.
struct ScriptMatcher {
    let words: [String]
    /// Index of the next word to be said. Words before it have been read.
    private(set) var position = 0

    init(words: [String]) { self.words = words }

    /// Moves to a word, for example after a manual drag or a rewind.
    mutating func jump(to index: Int) {
        position = min(max(0, index), words.count)
    }

    /// Feeds the words heard so far in the current recognition pass.
    /// Returns true when the position moved forward.
    @discardableResult
    mutating func update(heard: [String]) -> Bool {
        guard !words.isEmpty, position < words.count else { return false }
        let tail = Array(heard.suffix(8))
        guard let last = tail.last else { return false }

        // Look a short way ahead first, so repeated phrases later in the script don't pull us forward.
        if let end = bestEnd(tail: tail, last: last, in: max(0, position - 2)...min(words.count - 1, position + 30), near: true) {
            return advance(to: end + 1)
        }
        // Skipped a chunk: accept a far jump only on strong evidence.
        if tail.count >= 5, position + 31 < words.count,
           let end = bestEnd(tail: tail, last: last, in: (position + 31)...(words.count - 1), near: false) {
            return advance(to: end + 1)
        }
        return false
    }

    private mutating func advance(to index: Int) -> Bool {
        guard index > position else { return false }
        position = min(index, words.count)
        return true
    }

    /// The script index the last heard word lines up with, or nil when nothing fits well enough.
    private func bestEnd(tail: [String], last: String, in range: ClosedRange<Int>, near: Bool) -> Int? {
        var best: (end: Int, value: Double)?
        for end in range where Self.similar(words[end], last) {
            let before = Array(tail.dropLast())
            let windowStart = max(0, end - before.count - 3)
            let score = 1 + Self.lcs(before, Array(words[windowStart..<end]))
            let distance = end - position
            let accepted: Bool
            if near {
                // The very next word alone is enough (it is what we expect to hear).
                // Further ahead needs more of the phrase to agree.
                accepted = (distance >= -1 && distance <= 1 && (score >= 2 || words[end].count >= 3 || tail.count == 1))
                    || (distance <= 8 && score >= 2)
                    || score >= 3
            } else {
                accepted = score >= 5
            }
            guard accepted else { continue }
            let value = Double(score) - 0.04 * Double(abs(distance))
            if best == nil || value > best!.value { best = (end, value) }
        }
        return best?.end
    }

    /// Longest common subsequence length, with fuzzy word equality.
    static func lcs(_ a: [String], _ b: [String]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var row = [Int](repeating: 0, count: b.count + 1)
        for x in a {
            var diagonal = 0
            for j in 1...b.count {
                let saved = row[j]
                row[j] = similar(x, b[j - 1]) ? diagonal + 1 : max(row[j], row[j - 1])
                diagonal = saved
            }
        }
        return row[b.count]
    }

    /// Same word, allowing for small recognition slips ("color" / "colour", "gonna" / "going").
    static func similar(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let shorter = min(a.count, b.count)
        guard shorter >= 4 else { return false }
        if a.hasPrefix(b) || b.hasPrefix(a) { return true }
        let allowed = shorter >= 7 ? 2 : 1
        return editDistance(a, b, limit: allowed) <= allowed
    }

    static func editDistance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        var previous = Array(0...b.count)
        for i in 1...a.count {
            var current = [i] + [Int](repeating: 0, count: b.count)
            for j in 1...b.count {
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            previous = current
        }
        return previous[b.count]
    }
}
