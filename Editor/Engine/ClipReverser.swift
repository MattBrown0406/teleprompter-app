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
        let (size, transform, nominalRate) = try await track.load(.naturalSize, .preferredTransform, .nominalFrameRate)
        let fps = nominalRate > 0 ? Double(nominalRate) : Double(Video.frameRate)

        let out = MediaLibrary.newFile(in: MediaLibrary.media, ext: "mov")
        let writer = try AVAssetWriter(outputURL: out, fileType: .mov)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: Int(size.width.rounded()),
            AVVideoHeightKey: Int(size.height.rounded()),
        ])
        input.transform = transform
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: nil)
        guard writer.canAdd(input) else { throw EditorError.exportFailed("Couldn't write the reversed clip.") }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? EditorError.exportFailed("Couldn't write the reversed clip.") }
        writer.startSession(atSourceTime: .zero)

        // Each decoded 4K frame is about 12 MB and a whole chunk is held at once, so keep
        // chunks to a few frames at 4K (or 60 fps) instead of a fixed second.
        let isLarge = size.width * size.height > 1920 * 1080 * 1.1
        let framesPerChunk = isLarge ? 12.0 : 30.0
        let chunk = framesPerChunk / fps

        var chunkEnd = end
        var firstOut: Double?
        var lastPTS = CMTime.negativeInfinity

        do {
            while chunkEnd > start + 0.001 {
                try Task.checkCancellation()
                let chunkStart = max(start, chunkEnd - chunk)
                let reader = try AVAssetReader(asset: asset)
                let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                ])
                reader.add(output)
                reader.timeRange = CMTimeRange(start: chunkStart.cmTime, end: chunkEnd.cmTime)
                guard reader.startReading() else {
                    throw reader.error ?? EditorError.exportFailed("Couldn't read the clip.")
                }
                var frames: [(buffer: CVPixelBuffer, time: Double)] = []
                while let sample = output.copyNextSampleBuffer() {
                    let t = CMSampleBufferGetPresentationTimeStamp(sample).seconds
                    // The reader also returns frames that only overlap the range. Keep each frame
                    // in exactly one chunk, or the frame at every chunk boundary shows twice.
                    guard t.isFinite, t >= chunkStart - 0.0005, t < chunkEnd - 0.0005,
                          let pb = CMSampleBufferGetImageBuffer(sample) else { continue }
                    frames.append((pb, t))
                }
                if reader.status == .failed {
                    throw reader.error ?? EditorError.exportFailed("Couldn't read the clip.")
                }
                for frame in frames.reversed() {
                    // Mirror each frame's time around the end of the range, so the reversed clip
                    // keeps the source's frame rate and length (a 60 fps clip isn't slowed down).
                    let mirrored = end - frame.time
                    if firstOut == nil { firstOut = mirrored }
                    let pts = CMTime(seconds: mirrored - (firstOut ?? 0), preferredTimescale: 60_000)
                    guard pts > lastPTS else { continue }
                    while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 5_000_000) }
                    if !adaptor.append(frame.buffer, withPresentationTime: pts) {
                        throw writer.error ?? EditorError.exportFailed("Couldn't write the reversed clip.")
                    }
                    lastPTS = pts
                }
                chunkEnd = chunkStart
            }
            guard lastPTS.isNumeric else { throw EditorError.exportFailed("No frames to reverse.") }
            input.markAsFinished()
            writer.endSession(atSourceTime: lastPTS + CMTime(seconds: 1 / fps, preferredTimescale: 60_000))
            await writer.finishWriting()
            guard writer.status == .completed else {
                throw writer.error ?? EditorError.exportFailed("Couldn't finish the reversed clip.")
            }
        } catch {
            if writer.status == .writing { writer.cancelWriting() }
            try? FileManager.default.removeItem(at: out)
            throw error
        }
        return out
    }
}
