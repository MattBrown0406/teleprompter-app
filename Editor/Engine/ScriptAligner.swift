import Foundation

/// Lines up recognised words with the script that was read, so captions use the script's exact
/// spelling and punctuation while keeping the timing of what was actually said.
enum ScriptAligner {
    struct Result {
        var words: [SpokenWord]
        /// Share of spoken words that matched the script, 0...1.
        var matchRate: Double
    }

    static func align(spoken: [SpokenWord], script: String) -> Result {
        let scriptWords = tokens(script)
        let n = scriptWords.count, m = spoken.count
        guard n > 0, m > 0 else { return Result(words: spoken, matchRate: 0) }
        // Keep memory sane on very long scripts: align against the part near the spoken length.
        guard n * m <= 6_000_000 else { return Result(words: spoken, matchRate: 0) }

        let a = scriptWords.map(Transcriber.normalize)
        let b = spoken.map { Transcriber.normalize($0.text) }

        // Edit-distance table (match 0, substitute 1, skip 1). Rows: script, columns: spoken.
        let cols = m + 1
        var cost = [Int32](repeating: 0, count: (n + 1) * cols)
        for i in 0...n { cost[i * cols] = Int32(i) }
        for j in 0...m { cost[j] = Int32(j) }
        for i in 1...n {
            for j in 1...m {
                let sub = cost[(i - 1) * cols + j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                let del = cost[(i - 1) * cols + j] + 1
                let ins = cost[i * cols + j - 1] + 1
                cost[i * cols + j] = min(sub, del, ins)
            }
        }

        enum Op { case pair(Int, Int), scriptOnly(Int), spokenOnly(Int) }
        var ops: [Op] = []
        var i = n, j = m
        while i > 0 || j > 0 {
            if i > 0, j > 0, cost[i * cols + j] == cost[(i - 1) * cols + j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1) {
                ops.append(.pair(i - 1, j - 1)); i -= 1; j -= 1
            } else if i > 0, cost[i * cols + j] == cost[(i - 1) * cols + j] + 1 {
                ops.append(.scriptOnly(i - 1)); i -= 1
            } else {
                ops.append(.spokenOnly(j - 1)); j -= 1
            }
        }
        ops.reverse()

        var matches = 0
        var out: [SpokenWord] = []
        var pendingScript: [Int] = []

        func flushPending(nextStart: Double?) {
            defer { pendingScript.removeAll() }
            // A short run of script words the recogniser missed: spread them over the gap.
            // A long run was probably skipped while recording, so leave it out.
            guard !pendingScript.isEmpty, pendingScript.count <= 3,
                  let prevEnd = out.last?.end, let nextStart, nextStart > prevEnd else { return }
            let step = (nextStart - prevEnd) / Double(pendingScript.count)
            for (k, idx) in pendingScript.enumerated() {
                let s = prevEnd + step * Double(k)
                out.append(SpokenWord(text: scriptWords[idx], start: s, end: s + step))
            }
        }

        for op in ops {
            switch op {
            case .pair(let si, let wi):
                flushPending(nextStart: spoken[wi].start)
                var w = spoken[wi]
                if a[si] == b[wi] { matches += 1; w.text = scriptWords[si] }
                else if similar(a[si], b[wi]) { matches += 1; w.text = scriptWords[si] }
                out.append(w)
            case .scriptOnly(let si):
                pendingScript.append(si)
            case .spokenOnly(let wi):
                flushPending(nextStart: spoken[wi].start)
                out.append(spoken[wi])  // said off-script: keep what was heard
            }
        }
        pendingScript.removeAll()

        let rate = Double(matches) / Double(m)
        // If the take doesn't follow the script, the plain transcript is more accurate.
        return rate >= 0.45 ? Result(words: out, matchRate: rate) : Result(words: spoken, matchRate: rate)
    }

    /// Script words, keeping punctuation attached. Stage directions in [brackets] are skipped.
    static func tokens(_ script: String) -> [String] {
        var cleaned = script
        while let open = cleaned.range(of: "["), let close = cleaned.range(of: "]", range: open.upperBound..<cleaned.endIndex) {
            cleaned.removeSubrange(open.lowerBound..<close.upperBound)
        }
        return cleaned.split { $0.isWhitespace || $0.isNewline }.map(String.init)
            .filter { !Transcriber.normalize($0).isEmpty }
    }

    /// Close spellings ("colour"/"color", "ok"/"okay") count as the same word.
    private static func similar(_ x: String, _ y: String) -> Bool {
        guard !x.isEmpty, !y.isEmpty else { return false }
        if x.hasPrefix(y) || y.hasPrefix(x) { return min(x.count, y.count) >= 2 }
        let xs = Array(x), ys = Array(y)
        guard abs(xs.count - ys.count) <= 2, max(xs.count, ys.count) >= 4 else { return false }
        var prev = Array(0...ys.count)
        for i in 1...xs.count {
            var cur = [i] + Array(repeating: 0, count: ys.count)
            for j in 1...ys.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (xs[i - 1] == ys[j - 1] ? 0 : 1))
            }
            prev = cur
        }
        return prev[ys.count] <= 2
    }
}
