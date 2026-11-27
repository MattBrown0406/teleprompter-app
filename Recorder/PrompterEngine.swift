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
        spokenIndex = 0
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
        follower.start(script: script)
    }

    private func heard(_ heardWords: [String]) {
        guard isScrolling, followsVoice, !isDragging else { return }
        if matcher.update(heard: heardWords) {
            spokenIndex = matcher.position
        }
    }

    private func resyncToOffset() {
        guard !wordOffsets.isEmpty, !words.isEmpty else { return }
        // First word whose line hasn't scrolled past the reading line yet.
        let index = wordOffsets.firstIndex { $0 >= offset - 2 } ?? words.count
        matcher.jump(to: min(index, words.count))
        spokenIndex = matcher.position
    }

    private var voiceTarget: CGFloat? {
        guard !wordOffsets.isEmpty else { return nil }
        let index = min(spokenIndex, wordOffsets.count - 1)
        return min(wordOffsets[index], maxOffset)
    }

    fileprivate func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0, !isDragging else { return }
        let dt = min(link.timestamp - lastTimestamp, 0.1)
        if followsVoice {
            guard let target = voiceTarget else { return }
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
