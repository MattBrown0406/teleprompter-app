import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import Metal

/// Custom compositor: draws each clip onto the canvas with framing, filters,
/// transitions and text, using Core Image on the GPU. Used for preview and export,
/// so what you see is what you get.
final class CanvasCompositor: NSObject, AVVideoCompositing {
    private let queue = DispatchQueue(label: "cueframe.compositor", qos: .userInteractive)
    private var renderContext: AVVideoCompositionRenderContext?
    private var cancelled = false

    static let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [.cacheIntermediates: false, .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB)!])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()
    private let colorSpace = CGColorSpace(name: CGColorSpace.itur_709) ?? CGColorSpaceCreateDeviceRGB()

    var sourcePixelBufferAttributes: [String: any Sendable]? {
        [kCVPixelBufferPixelFormatTypeKey as String: [kCVPixelFormatType_32BGRA,
                                                       kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                                                       kCVPixelFormatType_420YpCbCr8BiPlanarFullRange],
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    var requiredPixelBufferAttributesForRenderContext: [String: any Sendable] {
        [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
         kCVPixelBufferMetalCompatibilityKey as String: true]
    }

    func renderContextChanged(_ newRenderContext: AVVideoCompositionRenderContext) {
        queue.sync { renderContext = newRenderContext }
    }

    func startRequest(_ request: AVAsynchronousVideoCompositionRequest) {
        queue.async { [self] in
            if cancelled { request.finishCancelledRequest(); return }
            guard let instruction = request.videoCompositionInstruction as? CompositorInstruction,
                  let out = renderContext?.newPixelBuffer() else {
                request.finish(with: NSError(domain: "Cueframe", code: 1))
                return
            }
            let image = FrameRenderer.render(instruction: instruction, time: request.compositionTime) { trackID in
                request.sourceFrame(byTrackID: trackID).map { CIImage(cvPixelBuffer: $0) }
            }
            let size = instruction.plan.renderSize
            Self.ciContext.render(image, to: out, bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
            request.finish(withComposedVideoFrame: out)
        }
    }

    func cancelAllPendingVideoCompositionRequests() {
        cancelled = true
        queue.async(flags: .barrier) { self.cancelled = false }
    }
}

/// Pure frame maths, separate from AVFoundation plumbing.
enum FrameRenderer {
    static func render(instruction: CompositorInstruction, time: CMTime, source: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        let plan = instruction.plan
        let project = plan.project
        let size = plan.renderSize
        let canvasRect = CGRect(origin: .zero, size: size)
        let t = time.seconds

        let starts = project.clipStarts
        func layerImage(_ ref: LayerRef) -> CIImage {
            guard let index = project.clips.firstIndex(where: { $0.id == ref.clipID }),
                  let frame = source(ref.trackID) else {
                return background(project.background, nil, size)
            }
            let clip = project.clips[index]
            let sourceTime = clip.trimStart + (t - starts[index]) * clip.speed
            return place(frame, clip: clip, info: plan.clipInfo[clip.id], project: project, size: size, sourceTime: sourceTime)
        }

        var image: CIImage
        let a = layerImage(instruction.from)
        if let toRef = instruction.to {
            let b = layerImage(toRef)
            let range = instruction.transitionRange
            let p = max(0, min(1, (time - range.start).seconds / max(range.duration.seconds, 0.001)))
            image = Transitions.apply(instruction.transition, from: a, to: b, progress: ease(p), size: size)
        } else {
            image = a
        }

        image = OverlayRenderer.apply(project.overlayItems, to: image, at: t, instruction: instruction, plan: plan,
                                      size: size, source: source)

        let onBrandClip = project.clips.first(where: { $0.id == instruction.from.clipID })?.isBrandClip ?? false
        if let logo = project.logo, !onBrandClip, let mark = plan.logoImage(logo.path) {
            image = placeLogo(mark, logo: logo, size: size).composited(over: image)
        }
        for item in project.texts where t >= item.start && t < item.end {
            if let overlay = TextOverlay.image(for: item, at: t, canvas: size, cache: plan.textCache) {
                image = overlay.composited(over: image)
            }
        }
        return image.cropped(to: canvasRect)
    }

    static func placeLogo(_ mark: CIImage, logo: LogoOverlay, size: CGSize) -> CIImage {
        let w = mark.extent.width, h = mark.extent.height
        guard w > 0, h > 0 else { return mark }
        let targetW = size.width * CGFloat(logo.size)
        let s = targetW / w
        let margin = size.width * 0.045
        let lw = w * s, lh = h * s
        let left = logo.corner == .topLeft || logo.corner == .bottomLeft
        let top = logo.corner == .topLeft || logo.corner == .topRight
        let x: CGFloat = left ? margin : size.width - lw - margin
        // Core Image is y-up: "top" means a high y. Leave room for phone UI at the very top.
        let y: CGFloat = top ? size.height - lh - margin * 1.6 : margin * 1.6
        var img = mark.transformed(by: CGAffineTransform(translationX: -mark.extent.minX, y: -mark.extent.minY)
            .concatenating(CGAffineTransform(scaleX: s, y: s))
            .concatenating(CGAffineTransform(translationX: x, y: y)))
        if logo.opacity < 0.999 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(logo.opacity))])
        }
        return img
    }

    static func ease(_ x: Double) -> Double { x < 0.5 ? 2 * x * x : 1 - pow(-2 * x + 2, 2) / 2 }

    /// Orients the source frame, applies filters, and fits it onto the canvas.
    static func place(_ frame: CIImage, clip: ClipItem, info: ClipRenderInfo?, project: EditProject, size: CGSize,
                      sourceTime: Double? = nil) -> CIImage {
        var img = frame.oriented(orientation(for: info?.preferredTransform ?? .identity))
        if clip.rotation % 4 != 0 {
            let turns: [CGImagePropertyOrientation] = [.up, .right, .down, .left]
            img = img.oriented(turns[((clip.rotation % 4) + 4) % 4])
        }
        if clip.mirrored { img = img.oriented(.upMirrored) }
        img = img.transformed(by: CGAffineTransform(translationX: -img.extent.minX, y: -img.extent.minY))

        let w = img.extent.width, h = img.extent.height
        guard w > 0, h > 0 else { return background(project.background, nil, size) }
        let fitScale = clip.fit == .fill ? max(size.width / w, size.height / h) : min(size.width / w, size.height / h)
        let s: CGFloat = fitScale * CGFloat(clip.zoom)
        var placed = img.transformed(by: CGAffineTransform(scaleX: s, y: s))
        var baseX: CGFloat = (size.width - w * s) / 2
        var baseY: CGFloat = (size.height - h * s) / 2
        // Auto reframe: follow the face when the canvas crops the picture (e.g. 16:9 footage on 9:16).
        if project.autoReframe == true, clip.fit == .fill, clip.rotation % 4 == 0,
           let sourceTime, var face = clip.faces?.position(at: sourceTime) {
            if clip.mirrored { face.x = 1 - face.x }
            let c = FaceTracker.centering(face: face, imageSize: w * s, h * s, canvas: size)
            baseX = c.dx
            baseY = c.dy
        }
        let dx: CGFloat = baseX + CGFloat(clip.offset.x) * size.width
        let dy: CGFloat = baseY - CGFloat(clip.offset.y) * size.height
        placed = placed.transformed(by: CGAffineTransform(translationX: dx, y: dy))
        placed = Filters.apply(clip.filter, amount: clip.filterAmount, adjust: clip.adjust, to: placed)

        let covers = placed.extent.insetBy(dx: 0.5, dy: 0.5).contains(CGRect(origin: .zero, size: size))
        if covers { return placed }
        return placed.composited(over: background(project.background, img, size))
    }

    static func background(_ bg: CanvasBackground, _ frame: CIImage?, _ size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        switch bg {
        case .color(let c):
            return CIImage(color: CIColor(red: c.r, green: c.g, blue: c.b, alpha: 1)).cropped(to: rect)
        case .blur:
            guard let frame, frame.extent.width > 0 else { return CIImage(color: .black).cropped(to: rect) }
            let s = max(size.width / frame.extent.width, size.height / frame.extent.height) * 1.1
            let scaled = frame.transformed(by: CGAffineTransform(scaleX: s, y: s))
            let centered = scaled.transformed(by: CGAffineTransform(translationX: (size.width - scaled.extent.width) / 2,
                                                                    y: (size.height - scaled.extent.height) / 2))
            return centered.clampedToExtent()
                .applyingGaussianBlur(sigma: Double(size.width) * 0.035)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: -0.08, kCIInputSaturationKey: 1.1])
                .cropped(to: rect)
        }
    }

    /// Maps a track's preferredTransform to an EXIF orientation (handles iPhone portrait/landscape and front camera).
    static func orientation(for t: CGAffineTransform) -> CGImagePropertyOrientation {
        switch (t.a.rounded(), t.b.rounded(), t.c.rounded(), t.d.rounded()) {
        case (0, 1, -1, 0): return .right
        case (0, -1, 1, 0): return .left
        case (-1, 0, 0, -1): return .down
        case (0, 1, 1, 0): return .leftMirrored
        case (0, -1, -1, 0): return .rightMirrored
        case (-1, 0, 0, 1): return .upMirrored
        case (1, 0, 0, -1): return .downMirrored
        default: return .up
        }
    }
}
