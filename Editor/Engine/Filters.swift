import CoreImage

enum Filters {
    static func apply(_ kind: FilterKind, amount: Double, adjust: Adjustments, to input: CIImage) -> CIImage {
        var img = input
        if kind != .none {
            let filtered = look(kind, img)
            img = amount >= 0.999 ? filtered :
                img.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: filtered, kCIInputTimeKey: amount])
                .cropped(to: input.extent)
        }
        if !adjust.isIdentity { img = applyAdjustments(adjust, img) }
        return img
    }

    private static func look(_ kind: FilterKind, _ img: CIImage) -> CIImage {
        switch kind {
        case .none: return img
        case .vivid:
            return img.applyingFilter("CIVibrance", parameters: ["inputAmount": 0.5])
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.2, kCIInputContrastKey: 1.06])
        case .warmGlow:
            return tint(img, r: 1.08, g: 1.02, b: 0.88)
                .applyingFilter("CIColorControls", parameters: [kCIInputBrightnessKey: 0.02])
        case .coolBlue: return tint(img, r: 0.92, g: 1.0, b: 1.1)
        case .mono: return img.applyingFilter("CIPhotoEffectMono")
        case .noir: return img.applyingFilter("CIPhotoEffectNoir")
        case .fade: return img.applyingFilter("CIPhotoEffectFade")
        case .film: return img.applyingFilter("CIPhotoEffectTransfer")
        case .dusk: return img.applyingFilter("CIPhotoEffectProcess")
        case .mint:
            return tint(img, r: 0.94, g: 1.05, b: 1.0)
                .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 0.85])
        case .punch:
            return img.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.25, kCIInputContrastKey: 1.2])
        case .sepia: return img.applyingFilter("CISepiaTone", parameters: [kCIInputIntensityKey: 0.8])
        }
    }

    private static func tint(_ img: CIImage, r: CGFloat, g: CGFloat, b: CGFloat) -> CIImage {
        img.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: r, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: g, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: b, w: 0),
        ])
    }

    private static func applyAdjustments(_ a: Adjustments, _ input: CIImage) -> CIImage {
        var img = input.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: a.brightness, kCIInputContrastKey: a.contrast, kCIInputSaturationKey: a.saturation,
        ])
        if abs(a.warmth) > 0.01 {
            let w = CGFloat(a.warmth) * 0.12
            img = tint(img, r: 1 + w, g: 1, b: 1 - w)
        }
        if a.sharpen > 0.01 {
            img = img.applyingFilter("CISharpenLuminance", parameters: [kCIInputSharpnessKey: a.sharpen * 0.8])
        }
        if a.vignette > 0.01 {
            img = img.applyingFilter("CIVignette", parameters: [kCIInputIntensityKey: a.vignette * 1.5,
                                                                kCIInputRadiusKey: max(input.extent.width, input.extent.height) * 0.6])
        }
        return img.cropped(to: input.extent)
    }
}

enum Transitions {
    static func apply(_ kind: TransitionKind, from a: CIImage, to b: CIImage, progress p: Double, size: CGSize) -> CIImage {
        let rect = CGRect(origin: .zero, size: size)
        let A = a.cropped(to: rect), B = b.cropped(to: rect)
        switch kind {
        case .none:
            return p < 0.5 ? A : B
        case .crossfade:
            return dissolve(A, B, p)
        case .fadeBlack, .fadeWhite:
            let c = CIImage(color: kind == .fadeBlack ? .black : .white).cropped(to: rect)
            return p < 0.5 ? dissolve(A, c, p * 2) : dissolve(c, B, (p - 0.5) * 2)
        case .slideLeft:
            let x = size.width * p
            return A.transformed(by: .init(translationX: -x, y: 0))
                .composited(over: B.transformed(by: .init(translationX: size.width - x, y: 0)))
                .composited(over: CIImage(color: .black).cropped(to: rect))
        case .slideUp:
            let y = size.height * p
            return A.transformed(by: .init(translationX: 0, y: y))
                .composited(over: B.transformed(by: .init(translationX: 0, y: y - size.height)))
                .composited(over: CIImage(color: .black).cropped(to: rect))
        case .wipe:
            let revealed = B.cropped(to: CGRect(x: 0, y: 0, width: size.width * p, height: size.height))
            return revealed.composited(over: A)
        case .zoom:
            let s = 1 + p * 0.6
            let zoomed = A.transformed(by: CGAffineTransform(translationX: -size.width / 2, y: -size.height / 2)
                .concatenating(CGAffineTransform(scaleX: s, y: s))
                .concatenating(CGAffineTransform(translationX: size.width / 2, y: size.height / 2))).cropped(to: rect)
            return dissolve(zoomed, B, p)
        case .blur:
            let sigma = sin(p * .pi) * Double(size.width) * 0.03
            let mixed = dissolve(A, B, p)
            return sigma < 0.5 ? mixed : mixed.clampedToExtent().applyingGaussianBlur(sigma: sigma).cropped(to: rect)
        }
    }

    private static func dissolve(_ a: CIImage, _ b: CIImage, _ t: Double) -> CIImage {
        a.applyingFilter("CIDissolveTransition", parameters: [kCIInputTargetImageKey: b, kCIInputTimeKey: max(0, min(1, t))])
    }
}
