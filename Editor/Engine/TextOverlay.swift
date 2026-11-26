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
        let timed = timedWords(item)
        let look = item.look ?? .plain
        var active = -1
        if let timed, look != .plain {
            active = timed.lastIndex(where: { $0.start <= local }) ?? -1
            if look == .oneWord {
                // One word on screen at a time, each popping in.
                guard active >= 0 else { return nil }
                text = timed[active].text
                let p = min(1, (local - timed[active].start) / 0.14)
                scale = 0.75 + 0.25 * overshoot(p)
            }
        }

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
        let wordMode = timed != nil && look != .plain && look != .oneWord
        let key = "\(item.id)|\(text)|\(Int(pointSize))|\(Int(canvas.width))|\(item.style.hashValue)|\(look.rawValue)|\(wordMode ? active : -2)"
        guard let raster = cache.image(key: key, make: {
            if wordMode, let timed {
                return rasterizeWords(timed.map(\.text), active: active, look: look, style: item.style,
                                      pointSize: pointSize, maxWidth: canvas.width * 0.9)
            }
            return rasterize(text, style: item.style, pointSize: pointSize, maxWidth: canvas.width * 0.9)
        })
        else { return nil }

        let w = raster.extent.width, h = raster.extent.height
        var tf = CGAffineTransform(translationX: -w / 2, y: -h / 2)
        tf = tf.concatenating(CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale)))
        tf = tf.concatenating(CGAffineTransform(rotationAngle: CGFloat(-item.rotation * Double.pi / 180)))
        let cx: CGFloat = CGFloat(item.center.x) * canvas.width
        let cy: CGFloat = CGFloat(1 - item.center.y + rise) * canvas.height
        tf = tf.concatenating(CGAffineTransform(translationX: cx, y: cy))
        var img = raster.transformed(by: tf)
        if opacity < 0.999 {
            img = img.applyingFilter("CIColorMatrix", parameters: ["inputAVector": CIVector(x: 0, y: 0, z: 0, w: CGFloat(opacity))])
        }
        return img
    }

    /// Word timings that still match the caption text. Editing a word keeps its timing;
    /// adding or removing words falls back to a plain caption.
    static func timedWords(_ item: TextItem) -> [CaptionWord]? {
        guard var words = item.words, !words.isEmpty else { return nil }
        let tokens = item.text.split { $0.isWhitespace || $0.isNewline }.map(String.init)
        guard tokens.count == words.count else { return nil }
        for i in words.indices { words[i].text = tokens[i] }
        return words
    }

    static let defaultHighlight = RGBA(r: 1, g: 0.86, b: 0.1)

    /// Draws a caption line with the spoken word picked out.
    static func rasterizeWords(_ tokens: [String], active: Int, look: CaptionLook, style: TextStyle,
                               pointSize: CGFloat, maxWidth: CGFloat) -> CIImage? {
        let para = NSMutableParagraphStyle()
        para.alignment = style.alignment == .leading ? .left : style.alignment == .trailing ? .right : .center
        para.lineBreakMode = .byWordWrapping
        let font = uiFont(style, size: pointSize)
        let highlight = uiColor(style.highlightColor ?? defaultHighlight)
        let base = uiColor(style.color)
        let str = NSMutableAttributedString()
        var ranges: [NSRange] = []
        for (i, token) in tokens.enumerated() {
            if i > 0 { str.append(NSAttributedString(string: " ", attributes: [.font: font])) }
            var attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: base]
            switch look {
            case .highlight where i == active:
                attrs[.foregroundColor] = highlight
            case .box where i == active:
                attrs[.foregroundColor] = contrasting(style.highlightColor ?? defaultHighlight)
            case .reveal where i > active:
                attrs[.foregroundColor] = UIColor.clear  // keep the layout, hide words not said yet
            default:
                break
            }
            if style.outline && !(look == .reveal && i > active) && !(look == .box && i == active) {
                attrs[.strokeColor] = UIColor.black
                attrs[.strokeWidth] = -4.0
            }
            ranges.append(NSRange(location: str.length, length: (token as NSString).length))
            str.append(NSAttributedString(string: token, attributes: attrs))
        }
        str.addAttribute(.paragraphStyle, value: para, range: NSRange(location: 0, length: str.length))

        let storage = NSTextStorage(attributedString: str)
        let layout = NSLayoutManager()
        storage.addLayoutManager(layout)
        let container = NSTextContainer(size: CGSize(width: maxWidth, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        layout.addTextContainer(container)
        let glyphs = layout.glyphRange(for: container)
        let used = layout.usedRect(for: container).integral
        let padX = style.background == .none ? pointSize * 0.3 : pointSize * 0.45
        let padY = style.background == .none ? pointSize * 0.25 : pointSize * 0.25
        let size = CGSize(width: used.width + padX * 2, height: used.height + padY * 2)
        guard size.width > 1, size.height > 1 else { return nil }
        let origin = CGPoint(x: padX - used.minX, y: padY - used.minY)

        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(size: size, format: format).image { ctx in
            if style.background != .none {
                let radius = style.background == .pill ? size.height / 2 : pointSize * 0.2
                uiColor(style.backgroundColor).setFill()
                UIBezierPath(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: min(radius, size.height / 2)).fill()
            }
            if look == .box, active >= 0, active < ranges.count {
                let g = layout.glyphRange(forCharacterRange: ranges[active], actualCharacterRange: nil)
                let r = layout.boundingRect(forGlyphRange: g, in: container)
                    .offsetBy(dx: origin.x, dy: origin.y)
                    .insetBy(dx: -pointSize * 0.16, dy: -pointSize * 0.04)
                highlight.setFill()
                UIBezierPath(roundedRect: r, cornerRadius: pointSize * 0.18).fill()
            }
            if style.shadow && style.background == .none {
                ctx.cgContext.setShadow(offset: CGSize(width: 0, height: pointSize * 0.04), blur: pointSize * 0.18,
                                        color: UIColor.black.withAlphaComponent(0.6).cgColor)
            }
            layout.drawGlyphs(forGlyphRange: glyphs, at: origin)
        }
        guard let cg = image.cgImage else { return nil }
        return CIImage(cgImage: cg)
    }

    /// Black or white, whichever reads better on the colour.
    private static func contrasting(_ c: RGBA) -> UIColor {
        (0.299 * c.r + 0.587 * c.g + 0.114 * c.b) > 0.6 ? .black : .white
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

    /// The style's font, using an imported brand font when one is set and installed.
    static func uiFont(_ style: TextStyle, size: CGFloat) -> UIFont {
        if let name = style.customFont, let f = UIFont(name: name, size: size) { return f }
        return uiFont(style.font, size: size)
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
            .font: uiFont(style, size: pointSize),
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
