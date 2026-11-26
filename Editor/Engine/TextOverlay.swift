import UIKit
import CoreImage

/// Thread-safe cache of rasterised text, keyed by content and size.
final class TextImageCache: @unchecked Sendable {
    private let cache = NSCache<NSString, CIImage>()
    init() { cache.countLimit = 120 }
    func image(key: String, make: () -> CIImage?) -> CIImage? {
        if let hit = cache.object(forKey: key as NSString) { return hit }
        guard let made = make() else { return nil }
        cache.setObject(made, forKey: key as NSString)
        return made
    }
}

enum TextOverlay {
    /// The text item rendered and positioned on a canvas of `canvas` size (Core Image coordinates, y up).
    static func image(for item: TextItem, at t: Double, canvas: CGSize, cache: TextImageCache) -> CIImage? {
        let local = t - item.start
        let remaining = item.end - t
        let inDur = min(0.35, item.duration / 3)
        let outDur = min(0.25, item.duration / 3)
        var opacity = 1.0, scale = 1.0, rise = 0.0
        var text = item.text

        switch item.animation {
        case .none: break
        case .fade:
            opacity = min(1, local / inDur, remaining / outDur)
        case .pop:
            let p = min(1, local / inDur)
            scale = 0.6 + 0.4 * overshoot(p)
            opacity = min(1, p * 2, remaining / outDur)
        case .slideUp:
            let p = min(1, local / inDur)
            rise = (1 - p) * 0.04
            opacity = min(1, p, remaining / outDur)
        case .typewriter:
            let chars = Int(Double(text.count) * min(1, local / max(0.3, min(item.duration * 0.6, Double(text.count) * 0.05))))
            text = String(text.prefix(max(1, chars)))
            opacity = min(1, remaining / outDur)
        }
        opacity = max(0, min(1, opacity))
        guard opacity > 0.01, !text.isEmpty else { return nil }

        let pointSize = CGFloat(item.style.size * item.scale) * canvas.width
        let key = "\(item.id)|\(text)|\(Int(pointSize))|\(Int(canvas.width))|\(item.style.hashValue)"
        guard let raster = cache.image(key: key, make: { rasterize(text, style: item.style, pointSize: pointSize, maxWidth: canvas.width * 0.9) })
        else { return nil }

        let w = raster.extent.width, h = raster.extent.height
        var tf = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        tf = tf.concatenating(CGAffineTransform(scaleX: scale, y: scale))
        tf = tf.concatenating(CGAffineTransform(rotationAngle: -item.rotation * .pi / 180))
        let cx = item.center.x * canvas.width
        let cy = (1 - item.center.y + rise) * canvas.height
        tf = tf.concatenating(CGAffineTransform(translationX: cx, y: cy))
        var img = raster.transformed(by: tf)
        if opacity < 0.999 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: opacity)])
        }
        return img
    }

    private static func overshoot(_ p: Double) -> Double {
        let c1 = 1.70158, c3 = c1 + 1
        return 1 + c3 * pow(p - 1, 3) + c1 * pow(p - 1, 2)
    }

    static func uiFont(_ font: TextFont, size: CGFloat) -> UIFont {
        func design(_ d: UIFontDescriptor.SystemDesign, _ weight: UIFont.Weight) -> UIFont {
            let base = UIFont.systemFont(ofSize: size, weight: weight)
            return base.fontDescriptor.withDesign(d).map { UIFont(descriptor: $0, size: size) } ?? base
        }
        switch font {
        case .bold: return UIFont.systemFont(ofSize: size, weight: .heavy)
        case .rounded: return design(.rounded, .bold)
        case .serif: return design(.serif, .semibold)
        case .mono: return design(.monospaced, .bold)
        case .condensed: return UIFont(name: "AvenirNextCondensed-Heavy", size: size) ?? .systemFont(ofSize: size, weight: .black)
        case .light: return UIFont.systemFont(ofSize: size, weight: .light)
        }
    }

    static func uiColor(_ c: RGBA) -> UIColor { UIColor(red: c.r, green: c.g, blue: c.b, alpha: c.a) }

    /// Draws the text with its box, outline and shadow into an image.
    static func rasterize(_ text: String, style: TextStyle, pointSize: CGFloat, maxWidth: CGFloat) -> CIImage? {
        let para = NSMutableParagraphStyle()
        switch style.alignment {
        case .leading: para.alignment = .left
        case .center: para.alignment = .center
        case .trailing: para.alignment = .right
        }
        para.lineBreakMode = .byWordWrapping
        var attrs: [NSAttributedString.Key: Any] = [
            .font: uiFont(style.font, size: pointSize),
            .foregroundColor: uiColor(style.color),
            .paragraphStyle: para,
        ]
        if style.outline {
            attrs[.strokeColor] = UIColor.black
            attrs[.strokeWidth] = -4.0
        }
        let str = NSAttributedString(string: text, attributes: attrs)
        let bounds = str.boundingRect(with: CGSize(width: maxWidth, height: .greatestFiniteMagnitude),
                                      options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil).integral
        let padX = style.background == .none ? pointSize * 0.15 : pointSize * 0.45
        let padY = style.background == .none ? pointSize * 0.15 : pointSize * 0.25
        let size = CGSize(width: bounds.width + padX * 2, height: bounds.height + padY * 2)
        guard size.width > 1, size.height > 1 else { return nil }

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            let rect = CGRect(origin: .zero, size: size)
            if style.background != .none {
                let radius = style.background == .pill ? size.height / 2 : pointSize * 0.2
                uiColor(style.backgroundColor).setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: min(radius, size.height / 2)).fill()
            }
            if style.shadow && style.background == .none {
                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: pointSize * 0.04), blur: pointSize * 0.18,
                                        color: UIColor.black.withAlphaComponent(0.6).cgColor)
            }
            str.draw(with: CGRect(x: padX, y: padY, width: bounds.width, height: bounds.height),
                     options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
        }
        guard let cg = image.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }
}
