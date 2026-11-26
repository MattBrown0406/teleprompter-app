import AVFoundation
import Vision

/// Follows the main face through a clip so any canvas shape can keep it in frame.
enum FaceTracker {
    /// Samples the clip a few times a second and returns a smoothed face path (source seconds).
    static func track(url: URL, from start: Double, to end: Double,
                      progress: (@MainActor (Double) -> Void)? = nil) async throws -> [FaceSample] {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true   // upright frames, same as the compositor draws
        generator.maximumSize = CGSize(width: 480, height: 480)
        let tolerance = CMTime(value: 1, timescale: 10)
        generator.requestedTimeToleranceBefore = tolerance
        generator.requestedTimeToleranceAfter = tolerance

        let length = max(0, end - start)
        let step = length > 180 ? 0.5 : 0.25
        var raw: [FaceSample?] = []
        var times: [Double] = []
        var t = start
        while t <= end {
            try Task.checkCancellation()
            times.append(t)
            if let cg = try? await generator.image(at: t.cmTime).image {
                raw.append(largestFace(in: cg).map { FaceSample(t: t, x: $0.midX, y: $0.midY, h: $0.height) })
            } else {
                raw.append(nil)
            }
            if let progress, raw.count % 8 == 0 { await progress(length > 0 ? (t - start) / length : 1) }
            t += step
        }
        guard raw.contains(where: { $0 != nil }) else { return [] }
        return smooth(fillGaps(raw, times: times), radius: 4)
    }

    private static func largestFace(in image: CGImage) -> CGRect? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try? handler.perform([request])
        let faces = request.results ?? []
        return faces.max { $0.boundingBox.width * $0.boundingBox.height < $1.boundingBox.width * $1.boundingBox.height }?.boundingBox
    }

    /// Frames with no face hold the nearest known position.
    private static func fillGaps(_ raw: [FaceSample?], times: [Double]) -> [FaceSample] {
        var out: [FaceSample] = []
        var last: FaceSample? = raw.first(where: { $0 != nil }) ?? nil
        for (i, s) in raw.enumerated() {
            if let s { last = s }
            if let l = last { out.append(FaceSample(t: times[i], x: l.x, y: l.y, h: l.h)) }
        }
        return out
    }

    /// Moving average so the framing glides instead of twitching with every head movement.
    private static func smooth(_ s: [FaceSample], radius: Int) -> [FaceSample] {
        guard s.count > 2 else { return s }
        return s.indices.map { i in
            let lo = max(0, i - radius), hi = min(s.count - 1, i + radius)
            let n = Double(hi - lo + 1)
            var x = 0.0, y = 0.0, h = 0.0
            for k in lo...hi { x += s[k].x; y += s[k].y; h += s[k].h }
            return FaceSample(t: s[i].t, x: x / n, y: y / n, h: h / n)
        }
    }

    /// Pan (in canvas pixels) that puts the face near the centre while still covering the canvas.
    /// `w`,`h` is the scaled image size, `canvas` the output size.
    static func centering(face: FaceSample, imageSize w: CGFloat, _ h: CGFloat, canvas: CGSize) -> (dx: CGFloat, dy: CGFloat) {
        var dx = (canvas.width - w) / 2
        var dy = (canvas.height - h) / 2
        if w > canvas.width + 1 {
            dx = canvas.width / 2 - CGFloat(face.x) * w
            dx = min(0, max(canvas.width - w, dx))
        }
        if h > canvas.height + 1 {
            // Eyes sit a little above the middle; leave headroom.
            let target = canvas.height * 0.56
            dy = target - CGFloat(face.y) * h
            dy = min(0, max(canvas.height - h, dy))
        }
        return (dx, dy)
    }
}
