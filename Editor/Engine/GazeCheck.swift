import AVFoundation
import Vision

/// Finds moments where the speaker clearly looks away from the lens (down at notes, off to the side,
/// head turned), so they can be covered with B-roll.
///
/// It does not change your eyes. Apple has no API that redirects gaze in recorded video, and a homemade
/// eye warp looks uncanny, so the honest fix is to cover the glances. Small eye movements while
/// reading a prompter right under the lens are normal and are not flagged.
enum GazeCheck {
    struct Span: Identifiable, Equatable {
        let id = UUID()
        /// Timeline seconds.
        var start: Double
        var end: Double
        var reason: String
        var duration: Double { end - start }
    }

    private struct Sample {
        let t: Double
        let eyeX: Double?
        let eyeY: Double?
        let yaw: Double
        let pitch: Double
        let face: Bool
    }

    /// Checks every talking-head clip and returns look-away spans on the timeline, longest first.
    static func run(_ p: EditProject, progress: (@MainActor (Double) -> Void)? = nil) async throws -> [Span] {
        let body = p.clips.indices.filter { !p.clips[$0].isBrandClip }
        var spans: [Span] = []
        for (k, i) in body.enumerated() {
            let clip = p.clips[i]
            let samples = try await sample(url: clip.url, from: clip.trimStart, to: clip.effectiveTrimEnd) { f in
                await progress?((Double(k) + f) / Double(max(1, body.count)))
            }
            for s in flag(samples) {
                guard let a = p.timelineTime(clip: i, sourceTime: s.start),
                      let b = p.timelineTime(clip: i, sourceTime: s.end) else { continue }
                spans.append(Span(start: a, end: b, reason: s.reason))
            }
        }
        return spans.sorted { $0.start < $1.start }
    }

    private static func sample(url: URL, from start: Double, to end: Double,
                               progress: @escaping (Double) async -> Void) async throws -> [Sample] {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: url))
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: 720, height: 720)
        let tol = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol
        let length = max(0, end - start)
        let step = length > 300 ? 0.4 : 0.2
        var out: [Sample] = []
        var t = start
        var n = 0
        while t <= end {
            try Task.checkCancellation()
            if let cg = try? await generator.image(at: t.cmTime).image {
                out.append(measure(cg, t: t))
            }
            n += 1
            if n % 10 == 0 { await progress(length > 0 ? (t - start) / length : 1) }
            t += step
        }
        return out
    }

    private static func measure(_ image: CGImage, t: Double) -> Sample {
        let request = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        guard let face = (request.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            return Sample(t: t, eyeX: nil, eyeY: nil, yaw: 0, pitch: 0, face: false)
        }
        // Where each pupil sits inside its eye outline: 0 is centred, ±0.5 is at the corner.
        var xs: [Double] = [], ys: [Double] = []
        if let lm = face.landmarks {
            for (eye, pupil) in [(lm.leftEye, lm.leftPupil), (lm.rightEye, lm.rightPupil)] {
                guard let eye, let pupil, eye.pointCount > 3, let p = pupil.normalizedPoints.first else { continue }
                let pts = eye.normalizedPoints
                let minX = pts.map(\.x).min()!, maxX = pts.map(\.x).max()!
                let minY = pts.map(\.y).min()!, maxY = pts.map(\.y).max()!
                guard maxX - minX > 0.001, maxY - minY > 0.001 else { continue }
                xs.append(Double((p.x - (minX + maxX) / 2) / (maxX - minX)))
                ys.append(Double((p.y - (minY + maxY) / 2) / (maxY - minY)))
            }
        }
        return Sample(t: t,
                      eyeX: xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count),
                      eyeY: ys.isEmpty ? nil : ys.reduce(0, +) / Double(ys.count),
                      yaw: face.yaw?.doubleValue ?? 0,
                      pitch: face.pitch?.doubleValue ?? 0,
                      face: true)
    }

    /// Marks samples far from how the speaker usually looks, then joins them into spans of at least half a second.
    private static func flag(_ samples: [Sample]) -> [(start: Double, end: Double, reason: String)] {
        guard samples.count > 5 else { return [] }
        func median(_ v: [Double]) -> Double {
            let s = v.sorted()
            return s.isEmpty ? 0 : s[s.count / 2]
        }
        // Most of a take is spent reading next to the lens, so "normal" is the median.
        let mx = median(samples.compactMap(\.eyeX)), my = median(samples.compactMap(\.eyeY))
        let myaw = median(samples.filter(\.face).map(\.yaw)), mpitch = median(samples.filter(\.face).map(\.pitch))

        func reason(_ s: Sample) -> String? {
            guard s.face else { return "Out of frame" }
            if abs(s.yaw - myaw) > 0.35 { return "Head turned" }
            if s.pitch - mpitch > 0.3 || mpitch - s.pitch > 0.3 { return "Looking down or up" }
            if let x = s.eyeX, abs(x - mx) > 0.2 { return "Eyes off to the side" }
            if let y = s.eyeY, abs(y - my) > 0.28 { return "Eyes down" }
            return nil
        }

        var out: [(Double, Double, String)] = []
        var runStart: Double?
        var runReason = ""
        var last = 0.0
        for s in samples {
            if let r = reason(s) {
                if runStart == nil { runStart = s.t; runReason = r }
                last = s.t
            } else if let a = runStart {
                if last - a >= 0.35 { out.append((a, last + 0.2, runReason)) }
                runStart = nil
            }
        }
        if let a = runStart, last - a >= 0.35 { out.append((a, last + 0.2, runReason)) }
        // Join spans that are almost touching.
        var merged: [(Double, Double, String)] = []
        for s in out {
            if let l = merged.last, s.0 - l.1 < 0.5 { merged[merged.count - 1].1 = s.1 } else { merged.append(s) }
        }
        return merged.map { (max(0, $0.0 - 0.15), $0.1, $0.2) }
    }
}
