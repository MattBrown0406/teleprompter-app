import AVFoundation
import CoreImage

enum EditorError: LocalizedError {
    case noVideo(String)
    case exportFailed(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .noVideo(let name): return "\(name) has no video track."
        case .exportFailed(let why): return why
        case .cancelled: return "Cancelled."
        }
    }
}

/// Everything the player or exporter needs for one project.
struct BuiltComposition {
    let composition: AVMutableComposition
    let videoComposition: AVMutableVideoComposition
    let audioMix: AVMutableAudioMix
    let plan: RenderPlan
}

/// Per-clip facts the compositor needs at render time.
struct ClipRenderInfo {
    let preferredTransform: CGAffineTransform
    let naturalSize: CGSize
}

/// Shared, mutable render state. Instructions hold a reference, so style-only edits
/// (filters, text, framing) can be applied without rebuilding the composition.
final class RenderPlan: @unchecked Sendable {
    private let lock = NSLock()
    private var _project: EditProject
    let renderSize: CGSize
    let clipInfo: [UUID: ClipRenderInfo]
    let textCache = TextImageCache()

    init(project: EditProject, renderSize: CGSize, clipInfo: [UUID: ClipRenderInfo]) {
        _project = project
        self.renderSize = renderSize
        self.clipInfo = clipInfo
    }

    var project: EditProject {
        get { lock.lock(); defer { lock.unlock() }; return _project }
        set { lock.lock(); _project = newValue; lock.unlock() }
    }
}

/// One layer the compositor draws: which source track, which clip.
struct LayerRef {
    let trackID: CMPersistentTrackID
    let clipID: UUID
}

final class CompositorInstruction: NSObject, AVVideoCompositionInstructionProtocol {
    let timeRange: CMTimeRange
    let enablePostProcessing = false
    let containsTweening = true
    let requiredSourceTrackIDs: [NSValue]?
    let passthroughTrackID = kCMPersistentTrackID_Invalid

    let plan: RenderPlan
    let from: LayerRef
    let to: LayerRef?           // set during a transition
    let transition: TransitionKind

    init(timeRange: CMTimeRange, plan: RenderPlan, from: LayerRef, to: LayerRef? = nil, transition: TransitionKind = .none) {
        self.timeRange = timeRange
        self.plan = plan
        self.from = from
        self.to = to
        self.transition = transition
        var ids = [NSNumber(value: from.trackID)]
        if let to { ids.append(NSNumber(value: to.trackID)) }
        self.requiredSourceTrackIDs = ids
    }
}

enum CompositionBuilder {
    /// Short side of the preview render. Export uses the full project quality.
    static let previewShortSide: CGFloat = 720

    static func build(_ project: EditProject, renderScale: CGFloat? = nil, renderSize: CGSize? = nil,
                      includeExtraAudio: Bool = true) async throws -> BuiltComposition {
        let size: CGSize = {
            if let renderSize { return renderSize }
            let full = project.canvas.renderSize(project.quality)
            if renderScale != nil {
                let s = previewShortSide / min(full.width, full.height)
                return CGSize(width: (full.width * s).rounded(), height: (full.height * s).rounded())
            }
            return full
        }()

        let comp = AVMutableComposition()
        let videoTracks = [comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!,
                           comp.addMutableTrack(withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid)!]
        let audioTracks = [comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!,
                           comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)!]

        // Lay clips out alternately on tracks A and B so transitions can overlap.
        var starts: [CMTime] = []
        var ends: [CMTime] = []
        var infos: [UUID: ClipRenderInfo] = [:]
        var audioUsed = [false, false]
        var cursor = CMTime.zero

        for (i, clip) in project.clips.enumerated() {
            let asset = AVURLAsset(url: clip.url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
            guard let vTrack = try await asset.loadTracks(withMediaType: .video).first else {
                throw EditorError.noVideo(clip.url.lastPathComponent)
            }
            let (transform, natural) = try await vTrack.load(.preferredTransform, .naturalSize)
            infos[clip.id] = ClipRenderInfo(preferredTransform: transform, naturalSize: natural)

            let src = CMTimeRange(start: clip.trimStart.cmTime, duration: clip.trimmedDuration.cmTime)
            let outDur = clip.outputDuration.cmTime
            let k = i % 2
            let at = cursor
            try insert(vTrack, range: src, into: videoTracks[k], at: at, scaledTo: outDur)
            if let aTrack = try await asset.loadTracks(withMediaType: .audio).first {
                // Audio can be a few frames shorter than video; only insert what exists.
                let aRange = try await aTrack.load(.timeRange)
                let r = src.intersection(aRange)
                if r.duration.seconds > 0.01 {
                    let ratio = clip.speed
                    let aAt = at + CMTimeMultiplyByFloat64(r.start - src.start, multiplier: 1 / ratio)
                    let aOut = CMTimeMultiplyByFloat64(r.duration, multiplier: 1 / ratio)
                    try insert(aTrack, range: r, into: audioTracks[k], at: aAt, scaledTo: aOut)
                    audioUsed[k] = true
                }
            }
            starts.append(at)
            ends.append(at + outDur)
            cursor = at + outDur
            if i < project.clips.count - 1 { cursor = cursor - project.transitionDuration(after: i).cmTime }
        }

        let plan = RenderPlan(project: project, renderSize: size, clipInfo: infos)

        // Video instructions: pass segments and transition segments, contiguous.
        var instructions: [CompositorInstruction] = []
        for (i, clip) in project.clips.enumerated() {
            let layer = LayerRef(trackID: videoTracks[i % 2].trackID, clipID: clip.id)
            let passStart = i == 0 ? starts[i] : ends[i - 1]
            let passEnd = i < project.clips.count - 1 ? starts[i + 1] : ends[i]
            if passEnd > passStart {
                instructions.append(CompositorInstruction(timeRange: CMTimeRange(start: passStart, end: passEnd), plan: plan, from: layer))
            }
            if i < project.clips.count - 1, ends[i] > starts[i + 1] {
                let next = LayerRef(trackID: videoTracks[(i + 1) % 2].trackID, clipID: project.clips[i + 1].id)
                instructions.append(CompositorInstruction(timeRange: CMTimeRange(start: starts[i + 1], end: ends[i]),
                                                          plan: plan, from: layer, to: next, transition: clip.transitionOut))
            }
        }

        let vc = AVMutableVideoComposition()
        vc.customVideoCompositorClass = CanvasCompositor.self
        vc.renderSize = size
        vc.frameDuration = Video.frameDuration
        vc.instructions = instructions
        vc.colorPrimaries = AVVideoColorPrimaries_ITU_R_709_2
        vc.colorTransferFunction = AVVideoTransferFunction_ITU_R_709_2
        vc.colorYCbCrMatrix = AVVideoYCbCrMatrix_ITU_R_709_2

        // Audio: clip sound with crossfades, then music and voiceover.
        var params: [AVMutableAudioMixInputParameters] = []
        for k in 0..<2 where audioUsed[k] {
            let p = AVMutableAudioMixInputParameters(track: audioTracks[k])
            p.audioTimePitchAlgorithm = .spectral
            for i in stride(from: k, to: project.clips.count, by: 2) {
                let vol = project.clips[i].volume
                let fadeIn = i > 0 ? project.transitionDuration(after: i - 1) : 0
                let fadeOut = project.transitionDuration(after: i)
                var t = starts[i]
                if fadeIn > 0 {
                    p.setVolumeRamp(fromStartVolume: 0, toEndVolume: vol, timeRange: CMTimeRange(start: t, duration: fadeIn.cmTime))
                    t = t + fadeIn.cmTime
                }
                p.setVolume(vol, at: t)
                if fadeOut > 0 {
                    p.setVolumeRamp(fromStartVolume: vol, toEndVolume: 0,
                                    timeRange: CMTimeRange(start: ends[i] - fadeOut.cmTime, duration: fadeOut.cmTime))
                }
            }
            params.append(p)
        }
        for k in 0..<2 where !audioUsed[k] { comp.removeTrack(audioTracks[k]) }

        if includeExtraAudio {
            let total = cursor.seconds
            for item in project.audio where item.start < total {
                let asset = AVURLAsset(url: item.url)
                guard let aTrack = try await asset.loadTracks(withMediaType: .audio).first,
                      let track = comp.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else { continue }
                let length = min(item.duration, total - item.start)
                var placed = 0.0
                var srcStart = item.sourceStart
                while placed < length - 0.01 {
                    let available = item.sourceDuration - srcStart
                    guard available > 0.05 else { break }
                    let piece = min(available, length - placed)
                    try track.insertTimeRange(CMTimeRange(start: srcStart.cmTime, duration: piece.cmTime),
                                              of: aTrack, at: (item.start + placed).cmTime)
                    placed += piece
                    if !item.loop { break }
                    srcStart = 0
                }
                let p = AVMutableAudioMixInputParameters(track: track)
                let s = item.start
                let e = item.start + placed
                let fi = min(item.fadeIn, placed / 2)
                let fo = min(item.fadeOut, placed / 2)
                if fi > 0 {
                    p.setVolumeRamp(fromStartVolume: 0, toEndVolume: item.volume, timeRange: CMTimeRange(start: s.cmTime, duration: fi.cmTime))
                }
                p.setVolume(item.volume, at: (s + fi).cmTime)
                if fo > 0 {
                    p.setVolumeRamp(fromStartVolume: item.volume, toEndVolume: 0, timeRange: CMTimeRange(start: (e - fo).cmTime, duration: fo.cmTime))
                }
                params.append(p)
            }
        }
        // Rounding can leave a sound a tick longer than the picture. The video instructions
        // must cover the whole composition or playback and export fail, so trim the tail.
        if comp.duration > cursor {
            comp.removeTimeRange(CMTimeRange(start: cursor, end: comp.duration))
        }

        let mix = AVMutableAudioMix()
        mix.inputParameters = params

        return BuiltComposition(composition: comp, videoComposition: vc, audioMix: mix, plan: plan)
    }

    private static func insert(_ source: AVAssetTrack, range: CMTimeRange, into track: AVMutableCompositionTrack,
                               at: CMTime, scaledTo outDur: CMTime) throws {
        let end = track.timeRange.end
        if end.isValid, at > end {
            track.insertEmptyTimeRange(CMTimeRange(start: end, end: at))
        }
        try track.insertTimeRange(range, of: source, at: at)
        if CMTimeCompare(range.duration, outDur) != 0 {
            track.scaleTimeRange(CMTimeRange(start: at, duration: range.duration), toDuration: outDur)
        }
    }

    /// Fields that need a full rebuild when they change. Everything else is a style edit.
    static func structuralKey(_ p: EditProject) -> [AnyHashable] {
        var key: [AnyHashable] = [p.canvas.rawValue, p.quality.rawValue]
        for c in p.clips {
            key += [c.id, c.path, c.trimStart, c.effectiveTrimEnd, c.speed, c.volume, c.transitionOut.rawValue, c.transitionDuration]
        }
        for a in p.audio { key.append(a) }
        return key
    }
}
