import SwiftUI
import CoreMedia

// MARK: Report

/// Feedback from one practice run: how long it really took, how fast you spoke,
/// filler words, long pauses, and how much of the script you got through.
struct PracticeReport: Codable, Identifiable, Equatable {
    var id = UUID()
    var date = Date()
    /// Wall-clock length of the run, in seconds.
    var duration: TimeInterval
    /// What the script length predicts at 150 words a minute.
    var estimate: TimeInterval
    /// Words heard. 0 when speech recognition wasn't available.
    var wordsSpoken: Int
    /// Words per minute over the time you were speaking (long pauses left out).
    var wordsPerMinute: Int
    /// Filler words and phrases, most used first, beyond any the script itself contains.
    var fillers: [Filler]
    /// Pauses of 2 seconds or more between words.
    var longPauses: Int
    var longestPause: TimeInterval
    /// Share of the script you got through, 0 to 1.
    var coverage: Double
    var heardSpeech: Bool

    struct Filler: Codable, Equatable, Hashable {
        let word: String
        let count: Int
    }

    var fillerTotal: Int { fillers.reduce(0) { $0 + $1.count } }

    enum Pace { case slow, natural, fast }
    var pace: Pace {
        if wordsPerMinute < PracticeAnalyzer.slowBelow { return .slow }
        if wordsPerMinute > PracticeAnalyzer.fastAbove { return .fast }
        return .natural
    }

    /// Short, plain tips from the numbers.
    var tips: [String] {
        guard heardSpeech else {
            return ["Speech recognition didn't hear anything, so only the run time is measured. Check that the microphone and speech recognition are on for Cueframe."]
        }
        var tips: [String] = []
        switch pace {
        case .fast: tips.append("You're quick. Slow down a touch so every word lands, especially the hook.")
        case .slow: tips.append("You can pick up the pace. Short videos hold attention better at 140 to 170 words a minute.")
        case .natural: tips.append("Good pace for short video.")
        }
        let perMinute = duration > 0 ? Double(fillerTotal) / (duration / 60) : 0
        if perMinute >= 3, let top = fillers.first {
            tips.append("About \(Int(perMinute.rounded())) filler words a minute. Watch out for \u{201C}\(top.word)\u{201D}; a short silent pause works better.")
        } else if fillerTotal == 0 {
            tips.append("No filler words heard.")
        }
        if longPauses >= 3 {
            tips.append("\(longPauses) long pauses. If you lost your place, try a bigger text size or Follow my voice.")
        }
        if coverage < 0.85 {
            tips.append("You got through about \(Int((coverage * 100).rounded()))% of the script. Rehearse the parts you skipped, or cut them.")
        }
        if estimate > 0 {
            let over = duration - estimate
            if over > 10 { tips.append("The real run is \(Int(over.rounded())) s longer than the word count suggests. Plan your edit around \(RecorderFormat.time(duration)).") }
        }
        return tips
    }
}

// MARK: Analysis

/// Pure counting over what the recognizer heard, so it is easy to reason about.
enum PracticeAnalyzer {
    static let slowBelow = 130
    static let fastAbove = 175
    static let pauseThreshold: TimeInterval = 2

    /// Fillers we look for. Apple's recognizer often drops "um" and "uh", so those counts are a floor.
    static let singleFillers: Set<String> = ["um", "umm", "uh", "uhh", "uhm", "er", "erm", "ah", "hmm", "like", "basically", "actually", "literally", "honestly", "anyway"]
    static let phraseFillers: [[String]] = [["you", "know"], ["i", "mean"], ["kind", "of"], ["sort", "of"], ["you", "see"]]

    static func analyze(passes: [HeardPass], script: String, started: Date, ended: Date) -> PracticeReport {
        let duration = max(0, ended.timeIntervalSince(started))
        let scriptKeys = ScriptWords.keys(script)
        let estimate = Double(scriptKeys.count) / 150 * 60

        // Every word on one clock, in order.
        var timed: [(key: String, start: TimeInterval, end: TimeInterval)] = []
        for pass in passes.sorted(by: { $0.started < $1.started }) {
            let base = pass.started.timeIntervalSince(started)
            for segment in pass.segments {
                let keys = ScriptWords.keys(segment.text)
                for key in keys {
                    timed.append((key, base + segment.start, base + segment.start + segment.duration))
                }
            }
        }
        timed.sort { $0.start < $1.start }
        let heard = timed.map(\.key)

        var pauses: [TimeInterval] = []
        for i in timed.indices.dropFirst() {
            let gap = timed[i].start - timed[i - 1].end
            if gap >= pauseThreshold { pauses.append(gap) }
        }
        let speaking = max(1, duration - pauses.reduce(0, +))
        let wpm = heard.isEmpty ? 0 : Int((Double(heard.count) / (speaking / 60)).rounded())

        // Count fillers, minus the ones the script itself uses ("I like this" isn't a filler).
        let said = counts(in: heard), written = counts(in: scriptKeys)
        let fillers = said.compactMap { word, count -> PracticeReport.Filler? in
            let extra = count - (written[word] ?? 0)
            return extra > 0 ? PracticeReport.Filler(word: word, count: extra) : nil
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.word < $1.word }

        // How far through the script the speech got, using the same matcher as Follow my voice.
        var matcher = ScriptMatcher(words: scriptKeys)
        var window: [String] = []
        for key in heard {
            window.append(key)
            if window.count > 8 { window.removeFirst() }
            matcher.update(heard: window)
        }
        let coverage = scriptKeys.isEmpty ? 1 : Double(matcher.position) / Double(scriptKeys.count)

        return PracticeReport(
            duration: duration, estimate: estimate, wordsSpoken: heard.count, wordsPerMinute: wpm,
            fillers: fillers, longPauses: pauses.count, longestPause: pauses.max() ?? 0,
            coverage: min(1, coverage), heardSpeech: !heard.isEmpty)
    }

    /// Filler counts by display word.
    static func counts(in keys: [String]) -> [String: Int] {
        var result: [String: Int] = [:]
        var i = 0
        while i < keys.count {
            if let phrase = phraseFillers.first(where: { i + $0.count <= keys.count && Array(keys[i..<(i + $0.count)]) == $0 }) {
                result[phrase.joined(separator: " "), default: 0] += 1
                i += phrase.count
                continue
            }
            if singleFillers.contains(keys[i]) {
                result[canonical(keys[i]), default: 0] += 1
            }
            i += 1
        }
        return result
    }

    private static func canonical(_ word: String) -> String {
        switch word {
        case "umm", "uhm": return "um"
        case "uhh": return "uh"
        case "erm": return "er"
        default: return word
        }
    }
}

// MARK: Session

/// Runs a practice: times it, collects what the recognizer hears, and builds the report.
/// Main thread only, except `appendAudio`.
final class PracticeSession: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var startedAt: Date?
    /// Live words-per-minute while practicing.
    @Published private(set) var liveWordsPerMinute = 0
    @Published var report: PracticeReport?

    /// Used when the script isn't following your voice; otherwise the engine's listener is shared.
    private let ownListener = SpeechFollower()
    private weak var sharedListener: SpeechFollower?
    private var passes: [Int: HeardPass] = [:]
    private var script = ""
    private var scriptID: UUID?
    private let history = PracticeHistory()

    /// Starts timing and listening. Pass the engine's listener when it is already listening for Follow my voice,
    /// so two recognizers don't compete for the same audio.
    func start(script: String, scriptID: UUID?, shareListener: SpeechFollower?, microphone: Bool) {
        stopListening()
        self.script = script
        self.scriptID = scriptID
        passes = [:]
        liveWordsPerMinute = 0
        report = nil
        startedAt = Date()
        isRunning = true
        guard microphone else { return }
        let listener = shareListener ?? ownListener
        listener.onTranscript = { [weak self] pass in self?.heard(pass) }
        if shareListener == nil { ownListener.start(script: script) }
        sharedListener = shareListener
    }

    /// Stops and builds the report.
    func stop() {
        guard isRunning, let startedAt else { return }
        isRunning = false
        stopListening()
        let report = PracticeAnalyzer.analyze(passes: Array(passes.values), script: script, started: startedAt, ended: Date())
        if let scriptID { history.add(report, for: scriptID) }
        self.startedAt = nil
        self.report = report
    }

    func cancel() {
        isRunning = false
        startedAt = nil
        stopListening()
    }

    /// The run before this one for the same script, for comparison.
    func previous(for scriptID: UUID?, before report: PracticeReport) -> PracticeReport? {
        guard let scriptID else { return nil }
        return history.runs(for: scriptID).first { $0.id != report.id && $0.date < report.date }
    }

    /// Microphone audio from the camera. Safe from any thread.
    func appendAudio(_ buffer: CMSampleBuffer) {
        ownListener.append(buffer)
    }

    private func stopListening() {
        ownListener.onTranscript = nil
        ownListener.stop()
        sharedListener?.onTranscript = nil
        sharedListener = nil
    }

    private func heard(_ pass: HeardPass) {
        guard isRunning, let startedAt else { return }
        passes[pass.id] = pass
        let words = passes.values.reduce(0) { $0 + $1.segments.reduce(0) { $0 + ScriptWords.keys($1.text).count } }
        let minutes = Date().timeIntervalSince(startedAt) / 60
        if minutes > 0.1 { liveWordsPerMinute = Int((Double(words) / minutes).rounded()) }
    }
}

/// The last few practice runs per script, kept in UserDefaults.
final class PracticeHistory {
    private let key = "rec.practiceHistory"
    private let keep = 10

    func runs(for scriptID: UUID) -> [PracticeReport] {
        all()[scriptID.uuidString] ?? []
    }

    func add(_ report: PracticeReport, for scriptID: UUID) {
        var everything = all()
        var runs = everything[scriptID.uuidString] ?? []
        runs.insert(report, at: 0)
        everything[scriptID.uuidString] = Array(runs.prefix(keep))
        if let data = try? JSONEncoder().encode(everything) { UserDefaults.standard.set(data, forKey: key) }
    }

    private func all() -> [String: [PracticeReport]] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: [PracticeReport]].self, from: data) else { return [:] }
        return decoded
    }
}

// MARK: Views

/// Timer and live pace shown at the top while practicing.
struct PracticeBadge: View {
    @ObservedObject var session: PracticeSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.5)) { context in
            HStack(spacing: 8) {
                Image(systemName: "figure.mind.and.body").foregroundStyle(Theme.accent2)
                Text("Practice \(RecorderFormat.time(context.date.timeIntervalSince(session.startedAt ?? context.date)))")
                    .font(.subheadline.monospacedDigit().weight(.semibold))
                if session.liveWordsPerMinute > 0 {
                    Text("· \(session.liveWordsPerMinute) wpm")
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(Theme.textDim)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Practicing, nothing is being recorded")
        }
    }
}

/// The feedback after a practice run.
struct PracticeReportView: View {
    let report: PracticeReport
    let previous: PracticeReport?
    let onPracticeAgain: () -> Void
    let onRecord: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    stat("Real run time", RecorderFormat.time(report.duration),
                         detail: report.estimate > 0 ? "Word count suggested \(RecorderFormat.time(report.estimate))" : nil,
                         change: previous.map { delta(report.duration - $0.duration, unit: "s") })
                    if report.heardSpeech {
                        stat("Pace", "\(report.wordsPerMinute) words a minute", detail: paceText,
                             change: previous.flatMap { $0.heardSpeech ? delta(Double(report.wordsPerMinute - $0.wordsPerMinute), unit: " wpm") : nil })
                        stat("Filler words", "\(report.fillerTotal)",
                             detail: report.fillers.isEmpty ? nil : report.fillers.prefix(5).map { "\($0.word) \u{00D7}\($0.count)" }.joined(separator: ", "),
                             change: previous.flatMap { $0.heardSpeech ? delta(Double(report.fillerTotal - $0.fillerTotal), unit: "") : nil })
                        stat("Long pauses", "\(report.longPauses)",
                             detail: report.longPauses > 0 ? "Longest \(String(format: "%.1f", report.longestPause)) s" : "None over 2 seconds",
                             change: nil)
                        stat("Script covered", "\(Int((report.coverage * 100).rounded()))%", detail: nil, change: nil)
                    }
                } header: {
                    Text("Nothing was recorded")
                } footer: {
                    if report.heardSpeech {
                        Text("Apple's speech recognition sometimes leaves out \u{201C}um\u{201D} and \u{201C}uh\u{201D}, so the real filler count can be a little higher. Words the script itself uses aren't counted as fillers.")
                    }
                }

                Section("Tips") {
                    ForEach(report.tips, id: \.self) { Text($0) }
                }
            }
            .navigationTitle("Practice feedback")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
            }
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 12) {
                    Button { dismiss(); onPracticeAgain() } label: {
                        Label("Practice again", systemImage: "arrow.counterclockwise").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                    Button { dismiss(); onRecord() } label: {
                        Label("Record it", systemImage: "record.circle").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                }
                .controlSize(.large)
                .padding()
                .background(.bar)
            }
        }
    }

    private var paceText: String {
        switch report.pace {
        case .slow: return "On the slow side for short video"
        case .natural: return "Natural for short video (\(PracticeAnalyzer.slowBelow) to \(PracticeAnalyzer.fastAbove))"
        case .fast: return "Fast. Viewers may miss words"
        }
    }

    private func delta(_ value: Double, unit: String) -> String {
        let rounded = Int(value.rounded())
        if rounded == 0 { return "same as last time" }
        return "\(rounded > 0 ? "+" : "")\(rounded)\(unit) vs last time"
    }

    private func stat(_ title: String, _ value: String, detail: String?, change: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).foregroundStyle(Theme.textDim)
                Spacer()
                Text(value).font(.headline.monospacedDigit())
            }
            if let detail { Text(detail).font(.footnote).foregroundStyle(Theme.textDim) }
            if let change { Text(change).font(.caption).foregroundStyle(Theme.accent2) }
        }
        .accessibilityElement(children: .combine)
    }
}
