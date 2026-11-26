import SwiftUI
import QuartzCore

/// Drives the script scroll, frame by frame, so it stays smooth at 60 or 120 Hz.
///
/// Keep this out of views that don't draw the script: it publishes on every frame.
/// Hold it with `@State` (not `@StateObject`) in parent views.
final class PrompterEngine: ObservableObject {
    /// How far the script has scrolled, in points.
    @Published var offset: CGFloat = 0
    @Published private(set) var isScrolling = false

    /// Points per second.
    var speed: Double = 60
    /// Set by the script view once it knows how tall the text is.
    var maxOffset: CGFloat = .greatestFiniteMagnitude

    var isAtEnd: Bool { offset >= maxOffset - 1 }

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    func play() {
        guard !isScrolling else { return }
        if isAtEnd { offset = 0 }
        isScrolling = true
        lastTimestamp = 0
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
    }

    func toggle() { isScrolling ? pause() : play() }

    func rewind() {
        pause()
        offset = 0
    }

    /// Moves the script by hand, e.g. from a drag or a remote's arrow keys.
    func nudge(by delta: CGFloat) {
        offset = min(max(0, offset + delta), maxOffset)
    }

    fileprivate func tick(_ link: CADisplayLink) {
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else { return }
        let dt = min(link.timestamp - lastTimestamp, 0.1)
        offset = min(offset + CGFloat(speed * dt), maxOffset)
        if isAtEnd { pause() }
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
