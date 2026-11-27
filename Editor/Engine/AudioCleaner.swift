import AVFoundation
import Accelerate

/// One-tap voice cleanup: rumble filter, background-noise reduction, even loudness and a peak limiter.
/// Produces a new sound file with exactly the same timing as the source video.
enum AudioCleaner {
    enum Strength: String, CaseIterable, Identifiable, Codable {
        case light, standard, strong
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
        /// How hard noise is subtracted, and how far quiet bins are pushed down.
        var overSubtract: Float { self == .light ? 1.2 : self == .standard ? 1.8 : 2.6 }
        var floorGain: Float { self == .light ? 0.25 : self == .standard ? 0.12 : 0.06 }
    }

    static let sampleRate = 48_000.0

    static func outputURL(for source: URL, strength: Strength) -> URL {
        let base = source.deletingPathExtension().lastPathComponent
        return MediaLibrary.media.appendingPathComponent("clean-\(base)-\(strength.rawValue).caf")
    }

    /// Cleans a source file's sound. Reuses an earlier result for the same file and strength.
    static func clean(_ source: URL, strength: Strength, progress: (@MainActor (Double) -> Void)? = nil) async throws -> URL {
        let out = outputURL(for: source, strength: strength)
        if FileManager.default.fileExists(atPath: out.path) { return out }
        var x = try await AudioPCM.read(url: source, sampleRate: sampleRate)
        guard x.count > 4096 else { throw EditorError.exportFailed("This clip has no sound to clean.") }
        if let progress { await progress(0.15) }
        try Task.checkCancellation()
        highPass(&x, cutoff: 85)
        if let progress { await progress(0.25) }
        x = try denoise(x, strength: strength)
        if let progress { await progress(0.75) }
        try Task.checkCancellation()
        level(&x)
        limit(&x, ceiling: 0.89)
        if let progress { await progress(0.9) }
        // The reader starts at the first sound sample. When the sound track starts a little after the
        // video (common in recorded takes), put that gap back so the voice stays in sync with the lips.
        if let track = try? await AVURLAsset(url: source).loadTracks(withMediaType: .audio).first,
           let range = try? await track.load(.timeRange), range.start.seconds.isFinite, range.start.seconds > 0.001 {
            x.insert(contentsOf: repeatElement(0, count: Int((range.start.seconds * sampleRate).rounded())), at: 0)
        }
        // Write next to the final name and move it in, so an interrupted run never leaves
        // a half-written file that a later run would reuse.
        let partial = out.deletingLastPathComponent().appendingPathComponent(UUID().uuidString + ".caf")
        do {
            try write(x, to: partial)
            try? FileManager.default.removeItem(at: out)
            try FileManager.default.moveItem(at: partial, to: out)
        } catch {
            try? FileManager.default.removeItem(at: partial)
            throw error
        }
        if let progress { await progress(1) }
        return out
    }

    // MARK: Rumble filter (2nd-order Butterworth high-pass)

    static func highPass(_ x: inout [Float], cutoff: Double) {
        let w = 2 * Double.pi * cutoff / sampleRate
        let cosw = cos(w), alpha = sin(w) / (2 * 0.7071)
        let a0 = 1 + alpha
        let b0 = (1 + cosw) / 2 / a0, b1 = -(1 + cosw) / a0, b2 = (1 + cosw) / 2 / a0
        let a1 = -2 * cosw / a0, a2 = (1 - alpha) / a0
        var x1 = 0.0, x2 = 0.0, y1 = 0.0, y2 = 0.0
        for i in x.indices {
            let v = Double(x[i])
            let y = b0 * v + b1 * x1 + b2 * x2 - a1 * y1 - a2 * y2
            x2 = x1; x1 = v; y2 = y1; y1 = y
            x[i] = Float(y)
        }
    }

    // MARK: Noise reduction (spectral gating)

    static func denoise(_ input: [Float], strength: Strength) throws -> [Float] {
        let n = 1024, hop = 256, half = n / 2
        let log2n = vDSP_Length(10)
        guard let setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2)) else { return input }
        defer { vDSP_destroy_fftsetup(setup) }

        var window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_DENORM))
        let frames = max(1, (input.count - n) / hop + 1)

        // Pass 1: energy of every frame (kept small: spectra are recomputed when needed).
        var energy = [Float](repeating: 0, count: frames)
        var re = [Float](repeating: 0, count: half), im = [Float](repeating: 0, count: half)
        var frame = [Float](repeating: 0, count: n)

        func forward(_ f: Int) {
            let start = f * hop
            for k in 0..<n { frame[k] = (start + k < input.count ? input[start + k] : 0) * window[k] }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    frame.withUnsafeBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                        }
                    }
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                }
            }
        }

        func magnitude(_ k: Int) -> Float {
            if k == 0 { return abs(re[0]) }
            if k == half { return abs(im[0]) }
            return (re[k] * re[k] + im[k] * im[k]).squareRoot()
        }

        for f in 0..<frames {
            if f % 256 == 0 { try Task.checkCancellation() }
            let start = f * hop
            var e: Float = 0
            for k in 0..<n where start + k < input.count { e += input[start + k] * input[start + k] * window[k] }
            energy[f] = e
        }

        // Noise profile: average spectrum of the quietest 10% of frames (pauses between words).
        let quiet = energy.indices.sorted { energy[$0] < energy[$1] }.prefix(max(1, frames / 10))
        var noise = [Float](repeating: 0, count: half + 1)
        for f in quiet {
            forward(f)
            for k in 0...half { noise[k] += magnitude(k) }
        }
        for k in 0...half { noise[k] /= Float(quiet.count) }

        // Pass 2: gain per bin, smoothed over time to avoid "musical" noise, then resynthesise.
        var out = [Float](repeating: 0, count: input.count + n)
        var smoothed = [Float](repeating: 1, count: half + 1)
        let over = strength.overSubtract, floorGain = strength.floorGain
        for f in 0..<frames {
            if f % 256 == 0 { try Task.checkCancellation() }
            forward(f)
            for k in 0...half {
                let m = max(magnitude(k), 1e-9)
                let g = max(floorGain, 1 - over * noise[k] / m)
                // Fast attack when speech starts, slower release.
                let coef: Float = g > smoothed[k] ? 0.6 : 0.25
                smoothed[k] += (g - smoothed[k]) * coef
            }
            re[0] *= smoothed[0]
            im[0] *= smoothed[half]
            for k in 1..<half { re[k] *= smoothed[k]; im[k] *= smoothed[k] }
            re.withUnsafeMutableBufferPointer { rp in
                im.withUnsafeMutableBufferPointer { ip in
                    var split = DSPSplitComplex(realp: rp.baseAddress!, imagp: ip.baseAddress!)
                    vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_INVERSE))
                    frame.withUnsafeMutableBufferPointer { fp in
                        fp.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                            vDSP_ztoc(&split, 1, $0, 2, vDSP_Length(half))
                        }
                    }
                }
            }
            // zrip forward+inverse scales by 2n; Hann windows at 75% overlap sum to 2.
            let scale = 1 / Float(2 * n) / 2
            let start = f * hop
            for k in 0..<n { out[start + k] += frame[k] * scale }
        }
        return Array(out.prefix(input.count))
    }

    // MARK: Leveling

    /// Brings speech to an even loudness (about -18 dBFS RMS), without lifting the room noise in pauses.
    static func level(_ x: inout [Float]) {
        let win = Int(sampleRate * 0.05)
        guard x.count > win else { return }
        var rms: [Float] = []
        var i = 0
        while i < x.count {
            let end = min(x.count, i + win)
            var s: Float = 0
            vDSP_svesq(Array(x[i..<end]), 1, &s, vDSP_Length(end - i))
            rms.append((s / Float(end - i)).squareRoot())
            i = end
        }
        let sorted = rms.sorted()
        let floor = sorted[Int(Double(sorted.count - 1) * 0.15)]
        let speechLevel = sorted[Int(Double(sorted.count - 1) * 0.8)]
        let gate = max(floor * 2.5, speechLevel * 0.12)
        let target: Float = 0.126 // -18 dBFS

        var gains = [Float](repeating: 1, count: rms.count)
        var g: Float = min(4, target / max(speechLevel, 1e-4))
        for k in rms.indices {
            let want: Float = rms[k] > gate ? min(4, max(0.25, target / max(rms[k], 1e-5))) : g
            // Slow moves so it sounds like a steady voice, not pumping.
            g += (want - g) * (want < g ? 0.3 : 0.08)
            gains[k] = g
        }
        for k in x.indices {
            let pos = Float(k) / Float(win)
            let a = min(gains.count - 1, Int(pos)), b = min(gains.count - 1, a + 1)
            let frac = pos - Float(a)
            x[k] *= gains[a] + (gains[b] - gains[a]) * frac
        }
    }

    /// Simple peak limiter so leveling never clips.
    static func limit(_ x: inout [Float], ceiling: Float) {
        var gain: Float = 1
        let release: Float = 1 / Float(sampleRate * 0.08)
        for i in x.indices {
            let peak = abs(x[i]) * gain
            if peak > ceiling { gain = ceiling / max(abs(x[i]), 1e-9) }
            x[i] *= gain
            gain = min(1, gain + release)
        }
    }

    private static func write(_ x: [Float], to url: URL) throws {
        try? FileManager.default.removeItem(at: url)
        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(x.count)) else {
            throw EditorError.exportFailed("Couldn't save the cleaned sound.")
        }
        buffer.frameLength = AVAudioFrameCount(x.count)
        x.withUnsafeBufferPointer { src in
            buffer.floatChannelData![0].update(from: src.baseAddress!, count: x.count)
        }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        let file = try AVAudioFile(forWriting: url, settings: settings, commonFormat: .pcmFormatFloat32, interleaved: false)
        try file.write(from: buffer)
    }
}
