import AVFoundation

/// Reads a file's sound as mono 32-bit float samples.
enum AudioPCM {
    static func read(url: URL, sampleRate: Double, range: CMTimeRange? = nil) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { return [] }
        let reader = try AVAssetReader(asset: asset)
        if let range { reader.timeRange = range }
        let settings: [String: Any] = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsBigEndianKey: false,
            AVLinearPCMIsNonInterleaved: false,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: sampleRate,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: settings)
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else { throw EditorError.exportFailed("Couldn't read the sound.") }
        reader.add(output)
        guard reader.startReading() else {
            throw EditorError.exportFailed(reader.error?.localizedDescription ?? "Couldn't read the sound.")
        }
        var samples: [Float] = []
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
            let length = CMBlockBufferGetDataLength(block)
            let count = length / MemoryLayout<Float>.size
            guard count > 0 else { continue }
            let start = samples.count
            samples.append(contentsOf: repeatElement(0, count: count))
            samples.withUnsafeMutableBytes { raw in
                let dest = raw.baseAddress!.advanced(by: start * MemoryLayout<Float>.size)
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: count * MemoryLayout<Float>.size, destination: dest)
            }
        }
        if reader.status == .failed {
            throw EditorError.exportFailed(reader.error?.localizedDescription ?? "Couldn't read the sound.")
        }
        return samples
    }

    /// Loudness in dBFS for each window of `window` seconds.
    static func levels(_ samples: [Float], sampleRate: Double, window: Double) -> [Float] {
        let size = max(1, Int(sampleRate * window))
        var out: [Float] = []
        out.reserveCapacity(samples.count / size + 1)
        var i = 0
        while i < samples.count {
            let end = min(samples.count, i + size)
            var sum: Float = 0
            for k in i..<end { sum += samples[k] * samples[k] }
            let rms = (sum / Float(end - i)).squareRoot()
            out.append(20 * log10(max(rms, 1e-6)))
            i = end
        }
        return out
    }
}
