import AVFoundation
import CoreImage
import ImageIO
import UniformTypeIdentifiers

/// Draws B-roll photos and videos over the talking head.
enum OverlayRenderer {
    static let fadeSeconds = 0.25

    static func apply(_ overlays: [OverlayItem], to base: CIImage, at t: Double, instruction: CompositorInstruction,
                      plan: RenderPlan, size: CGSize, source: (CMPersistentTrackID) -> CIImage?) -> CIImage {
        var image = base
        for ov in overlays where t >= ov.start && t < ov.end {
            let frame: CIImage?
            switch ov.kind {
            case .photo:
                frame = plan.logoImage(ov.path)
            case .video:
                guard let track = instruction.overlayTracks[ov.id], let raw = source(track) else { continue }
                let info = plan.clipInfo[ov.id]
                frame = raw.oriented(FrameRenderer.orientation(for: info?.preferredTransform ?? .identity))
            }
            guard let frame, frame.extent.width > 0, frame.extent.height > 0 else { continue }
            let local = t - ov.start
            var alpha = 1.0
            if ov.fade {
                let f = min(fadeSeconds, ov.duration / 3)
                if f > 0 { alpha = min(1, local / f, (ov.duration - local) / f) }
            }
            // A slow push-in keeps photos alive.
            let zoom: CGFloat = ov.kind == .photo && ov.motion ? 1 + 0.08 * CGFloat(min(1, local / max(ov.duration, 0.1))) : 1
            image = draw(frame, layout: ov.layout, over: image, size: size, zoom: zoom, alpha: max(0, alpha))
        }
        return image
    }

    static func draw(_ frame: CIImage, layout: OverlayItem.Layout, over base: CIImage, size: CGSize,
                     zoom: CGFloat, alpha: Double) -> CIImage {
        let canvas = CGRect(origin: .zero, size: size)
        let portrait = size.height >= size.width
        let m = size.width * 0.045
        var layer: CIImage
        switch layout {
        case .full:
            layer = fill(frame, into: canvas, zoom: zoom)
        case .corner:
            let w = size.width * (portrait ? 0.46 : 0.34)
            let h = w * (portrait ? 1.25 : 0.5625)
            let rect = CGRect(x: size.width - w - m, y: size.height - h - m * (portrait ? 3.2 : 1.2), width: w, height: h)
            let border = max(2, size.width * 0.006)
            let frameRect = CIImage(color: .white).cropped(to: rect.insetBy(dx: -border, dy: -border))
            layer = fill(frame, into: rect, zoom: zoom).composited(over: frameRect)
        case .speakerBubble:
            // B-roll full screen, and the speaker in a circle cut from the middle of the original picture.
            let full = fill(frame, into: canvas, zoom: zoom)
            let side = min(size.width, size.height) * 0.62
            let crop = CGRect(x: (size.width - side) / 2, y: size.height * 0.56 - side / 2, width: side, height: side)
            let d = min(size.width, size.height) * (portrait ? 0.34 : 0.3)
            let r = d / 2
            let center = CGPoint(x: m + r, y: size.height - m * (portrait ? 3.4 : 1.2) - r)
            let s = d / side
            let face = base.cropped(to: crop)
                .transformed(by: CGAffineTransform(translationX: -crop.minX, y: -crop.minY)
                    .concatenating(CGAffineTransform(scaleX: s, y: s))
                    .concatenating(CGAffineTransform(translationX: center.x - r, y: center.y - r)))
            let bubble = face.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: disk(center: center, radius: r),
            ])
            let ring = CIImage(color: .white).applyingFilter("CIBlendWithMask", parameters: [
                kCIInputBackgroundImageKey: CIImage.empty(),
                kCIInputMaskImageKey: disk(center: center, radius: r + max(2, size.width * 0.006)),
            ])
            layer = bubble.composited(over: ring).composited(over: full)
        }
        if alpha < 0.999 {
            layer = layer.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(alpha))])
        }
        return layer.composited(over: base).cropped(to: canvas)
    }

    /// Scales an image to cover a rectangle, centred, and crops it there.
    static func fill(_ image: CIImage, into rect: CGRect, zoom: CGFloat) -> CIImage {
        let img = image.transformed(by: CGAffineTransform(translationX: -image.extent.minX, y: -image.extent.minY))
        let w = img.extent.width, h = img.extent.height
        let s = max(rect.width / w, rect.height / h) * zoom
        return img.transformed(by: CGAffineTransform(scaleX: s, y: s)
            .concatenating(CGAffineTransform(translationX: rect.midX - w * s / 2, y: rect.midY - h * s / 2)))
            .cropped(to: rect)
    }

    /// White inside the circle, clear outside, with a soft one-pixel edge.
    private static func disk(center: CGPoint, radius: CGFloat) -> CIImage {
        let f = CIFilter(name: "CIRadialGradient", parameters: [
            "inputCenter": CIVector(x: center.x, y: center.y),
            "inputRadius0": max(0, radius - 1.5),
            "inputRadius1": radius,
            "inputColor0": CIColor(red: 1, green: 1, blue: 1, alpha: 1),
            "inputColor1": CIColor(red: 0, green: 0, blue: 0, alpha: 0),
        ])
        let rect = CGRect(x: center.x - radius - 2, y: center.y - radius - 2, width: radius * 2 + 4, height: radius * 2 + 4)
        return (f?.outputImage ?? CIImage.empty()).cropped(to: rect)
    }

    /// Saves picked photo data as an upright JPEG no larger than 4K, so huge camera photos stay quick to draw.
    static func savePhoto(_ data: Data) -> URL? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let opts: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: 3840,
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) else { return nil }
        let url = MediaLibrary.newFile(in: MediaLibrary.media, ext: "jpg")
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: 0.9] as CFDictionary)
        return CGImageDestinationFinalize(dest) ? url : nil
    }
}
