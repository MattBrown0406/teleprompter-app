import SwiftUI
import QuartzCore
import CoreMedia

/// Drives the script scroll, frame by frame, so it stays smooth at 60 or 120 Hz.
///
/// Two ways to scroll:
/// - fixed speed: moves at `speed` points per second.
/// - follow voice: listens, finds where you are in the script, and glides there,
///   so it keeps your pace and waits when you pause.
///
/// Keep this out of views that don't draw the script: it publishes on every frame.
/// Hold it with `@State` (not `@StateObject`) in parent views.
final class PrompterEngine: ObservableObject {
    /// How far the script has scrolled, in points.
    @Published var offset: CGFloat = 0
    @Published private(set) var isScrolling = false
    /// Index of the next word to say, when following your voice. Words before it are shown dimmer.
    @Published private(set) var spokenIndex = 0
    /// True while you keep talking but the words aren't in the script (an ad-lib).
    /// The script waits and picks up again when you're back on it.
    @Published private(set) var isOffScript = false

    /// Points per second, for fixed speed.
    var speed: Double = 60
    /// Set by the script view once it knows how tall the text is.
    var maxOffset: CGFloat = .greatestFiniteMagnitude
    /// True while a finger is dragging the script.
    var isDragging = false

    /// Follow the speaker instead of a fixed speed.
    var followsVoice = false {
        willSet { if newValue != followsVoice { objectWillChange.send() } }
        didSet {
            guard followsVoice != oldValue else { return }
            if isScrolling {
                if followsVoice { startListening() } else { follower.stop() }
            }
            if followsVoice { resyncToOffset() }
        }
    }

    /// Listens to the microphone. Feed it audio with `appendAudio`.
    let follower = SpeechFollower()

    private(set) var words: [ScriptWord] = []
    private var script = ""
    private var matcher = ScriptMatcher(words: [])
    /// Scroll offset that puts word i on the reading line, plus one entry for the end.
    private var wordOffsets: [CGFloat] = []

    // Pace: speech recognition reports words in bursts and a beat late. Between reports the
    // scroll keeps moving at your measured speaking rate, a word or two at most, so it feels
    // in step with your voice rather than catching up after you.
    /// Where the scroll is heading, in words (fractional). Never behind `spokenIndex`.
    private var predictedIndex: Double = 0
    /// Your speaking rate, words per second, smoothed.
    private var wordsPerSecond: Double = 2.5
    private var lastAdvanceTime: CFTimeInterval = 0
    /// Words heard since the last one that matched the script.
    private var unmatchedWords = 0
    private var lastHeardCount = 0
    /// How far ahead of the last confirmed word the scroll may run.
    private static let maxLead = 1.6
    /// After this long without a new word, you've paused: stop running ahead.
    private static let pauseGap: CFTimeInterval = 0.6

    var isAtEnd: Bool { offset >= maxOffset - 1 }

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    init() {
        follower.onWords = { [weak self] heard in self?.heard(heard) }
    }

    // MARK: Script and layout

    /// Called by the script view when the text changes.
    func setScript(_ text: String) {
        guard text != script else { return }
        script = text
        words = ScriptWords.tokenize(text)
        matcher = ScriptMatcher(words: words.map(\.key))
        matcher.allowsBackJump = true
        spokenIndex = 0
        resetPace()
        wordOffsets = []
    }

    /// Called by the script view when it has laid out the text.
    func setWordOffsets(_ offsets: [CGFloat]) {
        wordOffsets = offsets
    }

    /// Safe to call from any thread.
    func appendAudio(_ buffer: CMSampleBuffer) {
        follower.append(buffer)
    }

    // MARK: Control

    func play() {
        guard !isScrolling else { return }
        if isAtEnd && !followsVoice { offset = 0 }
        isScrolling = true
        lastTimestamp = 0
        if followsVoice { startListening() }
        let link = CADisplayLink(target: Ticker(self), selector: #selector(Ticker.tick(_:)))
        // Smooth on ProMotion screens (needs CADisableMinimumFrameDurationOnPhone in Info.plist).
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func pause() {
        isScrolling = false
        link?.invalidate()
        link = nil
        follower.stop()
    }

    func toggle() { isScrolling ? pause() : play() }

    func rewind() {
        pause()
        offset = 0
        matcher.jump(to: 0)
        spokenIndex = 0
        resetPace()
    }

    /// Moves the script by hand, e.g. from a drag or a remote's arrow keys.
    func nudge(by delta: CGFloat) {
        offset = min(max(0, offset + delta), maxOffset)
        if followsVoice { resyncToOffset() }
    }

    /// After a drag, start following from the line now on the reading line.
    func didScrollByHand() {
        isDragging = false
        if followsVoice { resyncToOffset() }
    }

    // MARK: Following

    private func startListening() {
        lastHeardCount = 0
        unmatchedWords = 0
        if isOffScript { isOffScript = false }
        follower.start(script: script)
    }

    private func heard(_ heardWords: [String]) {
        guard isScrolling, followsVoice, !isDragging else { return }
        // A shorter list means the recognizer started a fresh pass.
        let fresh = heardWords.count >= lastHeardCount ? heardWords.count - lastHeardCount : heardWords.count
        lastHeardCount = heardWords.count
        let before = matcher.position
        if matcher.update(heard: heardWords) {
            let now = CACurrentMediaTime()
            let after = matcher.position
            if after > before {
                // Measure pace only over short, steady stretches of speech.
                let elapsed = now - lastAdvanceTime
                let moved = Double(after - before)
                if lastAdvanceTime > 0, elapsed > 0.15, elapsed < 2.5, moved <= 12 {
                    let rate = min(max(moved / elapsed, 1.2), 5.5)
                    wordsPerSecond += (rate - wordsPerSecond) * 0.3
                }
                predictedIndex = max(predictedIndex, Double(after))
            } else {
                // Went back to redo a line: follow it.
                predictedIndex = Double(after)
            }
            lastAdvanceTime = now
            spokenIndex = after
            unmatchedWords = 0
            if isOffScript { isOffScript = false }
        } else if fresh > 0 {
            unmatchedWords += fresh
            if unmatchedWords >= 6 && !isOffScript { isOffScript = true }
        }
    }

    private func resetPace() {
        predictedIndex = Double(spokenIndex)
        lastAdvanceTime = 0
        unmatchedWords = 0
        if isOffScript { isOffScript = false }
    }

    private func resyncToOffset() {
        guard !wordOffsets.isEmpty, !words.isEmpty else { return }
        // First word whose line hasn't scrolled past the reading line yet.
        let index = wordOffsets.firstIndex { $0 >= offset - 2 } ?? words.count
        matcher.jump(to: min(index, words.count))
        spokenIndex = matcher.position
        resetPace()
    }

    /// Scroll offset for a fractional word index, between the two words' positions.
    private func voiceTarget(at index: Double) -> CGFloat? {
        guard !wordOffsets.isEmpty else { return nil }
        let last = wordOffsets.count - 1
        let clamped = min(max(0, index), Double(last))
        let lower = Int(clamped.rounded(.down))
        let upper = min(lower + 1, last)
        let t = CGFloat(clamped - Double(lower))
        return min(wordOffsets[lower] + (wordOffsets[upper] - wordOffsets[lower]) * t, maxOffset)
    }

    fileprivate func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0, !isDragging else { return }
        let dt = min(link.timestamp - lastTimestamp, 0.1)
        if followsVoice {
            // Keep moving at your pace while you're talking, but never more than a word or two
            // past what was heard, and stop as soon as you pause.
            let confirmed = Double(spokenIndex)
            if predictedIndex < confirmed { predictedIndex = confirmed }
            if lastAdvanceTime > 0, link.timestamp - lastAdvanceTime < Self.pauseGap, !isOffScript {
                predictedIndex = min(predictedIndex + wordsPerSecond * dt, confirmed + Self.maxLead)
            }
            guard let target = voiceTarget(at: predictedIndex) else { return }
            // Glide toward where you are, quickly but without jumps.
            let gap = target - offset
            guard abs(gap) > 0.25 else { return }
            offset += gap * CGFloat(1 - exp(-dt / 0.22))
        } else {
            offset = min(offset + CGFloat(speed * dt), maxOffset)
            if isAtEnd { pause() }
        }
    }

    /// Breaks the retain cycle between CADisplayLink and the engine.
    private final class Ticker: NSObject {
        weak var engine: PrompterEngine?
        init(_ engine: PrompterEngine) { self.engine = engine }
        @objc func tick(_ link: CADisplayLink) {
            guard let engine else { link.invalidate(); return }
            engine.tick(link)
        }
    }
}
