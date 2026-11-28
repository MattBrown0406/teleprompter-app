import AVFoundation
import CoreImage
import UIKit

/// One-tap colour and light fix. Looks at a few frames of each clip and sets the clip's
/// adjustments so every clip lands on the same brightness, contrast, colour and white balance.
enum LookPolish {
    /// What a clip's frames measure, on a 0...1 scale.
    struct Stats: Equatable {
        var luma: Double       // average brightness
        var spread: Double     // standard deviation of brightness (contrast)
        var chroma: Double     // average colourfulness
        var redMinusBlue: Double
        var redPlusBlue: Double
    }

    enum Strength: String, CaseIterable, Identifiable {
        case subtle, natural, bold
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        var amount: Double { self == .subtle ? 0.5 : self == .natural ? 0.8 : 1 }
    }

    // A bright, clean talking-head look.
    static let targetLuma = 0.5
    static let targetSpread = 0.22
    static let targetChroma = 0.16
    /// Skin-friendly balance: slightly more red than blue.
    static let targetRedMinusBlue = 0.06

    /// Samples a handful of frames from the used part of a clip.
    static func measure(_ clip: ClipItem) async throws -> Stats? {
        let asset = AVURLAsset(url: clip.url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 160)
        gen.requestedTimeToleranceBefore = CMTime(value: 1, timescale: 2)
        gen.requestedTimeToleranceAfter = CMTime(value: 1, timescale: 2)
        let n = 6
        var all: [Stats] = []
        for k in 0..<n {
            try Task.checkCancellation()
            let t = clip.trimStart + clip.trimmedDuration * (Double(k) + 0.5) / Double(n)
            guard let image = try? await gen.image(at: t.cmTime).image, let s = stats(of: image) else { continue }
            all.append(s)
        }
        guard !all.isEmpty else { return nil }
        // Median of each measure, so one dark or flashy frame doesn't swing the result.
        func median(_ f: (Stats) -> Double) -> Double {
            let v = all.map(f).sorted()
            return v[v.count / 2]
        }
        return Stats(luma: median(\.luma), spread: median(\.spread), chroma: median(\.chroma),
                     redMinusBlue: median(\.redMinusBlue), redPlusBlue: median(\.redPlusBlue))
    }

    static func stats(of image: CGImage) -> Stats? {
        let w = image.width, h = image.height
        guard w > 0, h > 0 else { return nil }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let drawn: Bool = px.withUnsafeMutableBytes { raw in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return nil }
        var sumL = 0.0, sumL2 = 0.0, sumC = 0.0, sumR = 0.0, sumB = 0.0
        let count = Double(w * h)
        for i in stride(from: 0, to: px.count, by: 4) {
            let r = Double(px[i]) / 255, g = Double(px[i + 1]) / 255, b = Double(px[i + 2]) / 255
            let l = 0.2126 * r + 0.7152 * g + 0.0722 * b
            sumL += l
            sumL2 += l * l
            sumC += max(r, g, b) - min(r, g, b)
            sumR += r
            sumB += b
        }
        let mean = sumL / count
        let spread = max(0, sumL2 / count - mean * mean).squareRoot()
        return Stats(luma: mean, spread: spread, chroma: sumC / count,
                     redMinusBlue: (sumR - sumB) / count, redPlusBlue: (sumR + sumB) / count)
    }

    /// Adjustments that move a clip from what it measures to the shared target. Kept gentle on purpose.
    static func adjustments(for s: Stats, strength: Strength, keeping old: Adjustments) -> Adjustments {
        let k = strength.amount
        var a = old
        a.brightness = clamp((targetLuma - s.luma) * 0.8 * k, -0.15, 0.15)
        a.contrast = clamp(1 + (targetSpread / max(s.spread, 0.05) - 1) * 0.6 * k, 0.9, 1.25)
        a.saturation = clamp(1 + (targetChroma / max(s.chroma, 0.03) - 1) * 0.5 * k, 0.85, 1.3)
        // Filters.applyAdjustments scales red up and blue down by warmth * 0.12.
        let shift = (targetRedMinusBlue - s.redMinusBlue) / max(s.redPlusBlue, 0.2)
        a.warmth = clamp(shift / 0.12 * k, -0.6, 0.6)
        a.sharpen = max(old.sharpen, 0.15 * k)
        return a
    }

    private static func clamp(_ v: Double, _ lo: Double, _ hi: Double) -> Double {
        let r = min(hi, max(lo, v))
        return (r * 1000).rounded() / 1000
    }
}
