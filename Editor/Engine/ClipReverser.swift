import AVFoundation

/// Makes a reversed copy of part of a clip (video only). Reads in short chunks from the end
/// so memory stays bounded even for 4K footage.
enum ClipReverser {
    static let maxSeconds = 60.0

    static func reverse(url: URL, start: Double, end: Double) async throws -> URL {
        guard end - start <= maxSeconds else {
            throw EditorError.exportFailed("Reverse works on clips up to \(Int(maxSeconds)) seconds. Trim or split it first.")
        }
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw EditorError.noVideo(url.lastPathComponent)
        }
        let (size, transform) = try await track.load(.naturalSize, .preferredTransform)
        let out = MediaLibrary.newFile(in: MediaLibrary.media, ext: "mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EditorError.exportFailed("Couldn't write the reversed clip.") }
        writer.startSession(atSourceTime: .zero)

        let chunk = 1.0
        var chunkEnd = end
        var outIndex: Int64 = 0

        while chunkEnd > start + 0.001 {
            let chunkStart = max(start, chunkEnd - chunk)
            let reader = try AVAssetReader(asset: asset)
            let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            ])
            reader.add(output)
            reader.timeRange = CMTimeRange(start: chunkStart.cmTime, end: chunkEnd.cmTime)
            reader.startReading()
            var frames: [CVPixelBuffer] = []
            while let sample = output.copyNextSampleBuffer() {
                if let pb = CMSampleBufferGetImageBuffer(sample) { frames.append(pb) }
            }
            for pb in frames.reversed() {
                while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
                let pts = CMTime(value: outIndex, timescale: Video.frameRate)
                if !adaptor.append(pb, withPresentationTime: pts) {
                    throw writer.error ?? EditorError.exportFailed("Couldn't write the reversed clip.")
                }
                outIndex += 1
            }
            chunkEnd = chunkStart
        }
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? EditorError.exportFailed("Couldn't finish the reversed clip.") }
        return out
    }
}
