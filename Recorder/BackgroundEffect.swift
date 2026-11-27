import SwiftUI
import UIKit
import PhotosUI
import AVFoundation
import Vision
import CoreImage
import CoreImage.CIFilterBuiltins

/// Replace or soften the background behind you, live, without a green screen.
/// Uses Vision person segmentation on every frame, so what you see is what records.
struct BackgroundEffect: Equatable, Codable {
    enum Kind: String, Codable, CaseIterable, Identifiable {
        case off, blur, color, photo
        var id: String { rawValue }
        var label: String {
            switch self {
            case .off: return "Off"
            case .blur: return "Blur"
            case .color: return "Color"
            case .photo: return "Photo"
            }
        }
    }

    var kind: Kind = .off
    /// 0 to 1: light to strong blur.
    var blurAmount: Double = 0.6
    /// The solid background, as RGB 0 to 1.
    var color: [Double] = [0.0, 0.69, 0.31]

    var isOn: Bool { kind != .off }

    static let swatches: [[Double]] = [
        [0.0, 0.69, 0.31],   // chroma green, for keying later
        [0.0, 0.28, 0.73],   // chroma blue
        [1, 1, 1], [0.08, 0.08, 0.1], [0.95, 0.42, 0.36], [0.98, 0.85, 0.55], [0.36, 0.78, 1.0], [0.55, 0.36, 0.86],
    ]

    /// Where a picked background photo is kept.
    static var photoURL: URL {
        let dir = MediaLibrary.documents.appendingPathComponent("Backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("background.jpg")
    }
}

/// Runs on the camera's data queue: segments the person in each frame and composites the background.
///
/// Speed: Vision's balanced model runs on the Neural Engine at a fixed small size, so its cost barely
/// changes with resolution. The blur is done at quarter size and scaled up, and Core Image draws on the
/// GPU. If a frame takes too long, the mask is refreshed every other frame instead (at 30 fps a one-frame-old
/// mask isn't visible), and `isStruggling` turns on so the screen can suggest 1080p.
final class BackgroundProcessor {
    private(set) var effect: BackgroundEffect
    private let context = CIContext(options: [.cacheIntermediates: false])
    private let request: VNGeneratePersonSegmentationRequest = {
        let r = VNGeneratePersonSegmentationRequest()
        r.qualityLevel = .balanced
        r.outputPixelFormat = kCVPixelFormatType_OneComponent8
        return r
    }()
    private let sequence = VNSequenceRequestHandler()
    private var pool: CVPixelBufferPool?
    private var poolSize: CGSize = .zero
    private var lastMask: CIImage?
    private var frame = 0
    private var everyOther = false
    private var averageMs: Double = 0
    private var backdrop: CIImage?
    private var backdropSize: CGSize = .zero

    /// True when frames take longer than the 33 ms a frame has at 30 fps.
    private(set) var isStruggling = false

    init(effect: BackgroundEffect) {
        self.effect = effect
        loadPhoto()
    }

    func update(_ effect: BackgroundEffect) {
        if effect.kind != self.effect.kind {
            // A fresh start: forget the old mask and timing.
            lastMask = nil
            averageMs = 0
            everyOther = false
            isStruggling = false
        }
        self.effect = effect
    }

    /// Reloads the picked photo after it changes.
    func reloadPhoto() {
        loadPhoto()
    }

    /// Returns a new sample buffer with the effect applied, or nil to use the original.
    func process(_ sampleBuffer: CMSampleBuffer) -> CMSampleBuffer? {
        guard effect.isOn, let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        let began = CACurrentMediaTime()
        let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
        let size = CGSize(width: width, height: height)

        frame &+= 1
        if lastMask == nil || !everyOther || frame % 2 == 0 {
            if (try? sequence.perform([request], on: pixels, orientation: .up)) != nil,
               let maskBuffer = request.results?.first?.pixelBuffer {
                lastMask = CIImage(cvPixelBuffer: maskBuffer)
            }
        }
        guard let rawMask = lastMask else { return nil }

        let camera = CIImage(cvPixelBuffer: pixels)
        // Scale the small mask up to the frame, and soften its edge a little so hair doesn't look cut out.
        let mask = rawMask
            .transformed(by: CGAffineTransform(scaleX: size.width / rawMask.extent.width, y: size.height / rawMask.extent.height))
            .applyingGaussianBlur(sigma: max(1, size.width / 1080 * 1.5))
            .cropped(to: camera.extent)

        guard let background = background(for: camera, size: size) else { return nil }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = camera
        blend.backgroundImage = background
        blend.maskImage = mask
        guard let output = blend.outputImage, let target = makeBuffer(size: size) else { return nil }
        context.render(output, to: target, bounds: camera.extent, colorSpace: CGColorSpace(name: CGColorSpace.itur_709))

        let ms = (CACurrentMediaTime() - began) * 1000
        averageMs = averageMs == 0 ? ms : averageMs * 0.9 + ms * 0.1
        if !everyOther && averageMs > 26 { everyOther = true }
        isStruggling = averageMs > 33

        return Self.sampleBuffer(with: target, timedLike: sampleBuffer)
    }

    private func background(for camera: CIImage, size: CGSize) -> CIImage? {
        switch effect.kind {
        case .off:
            return nil
        case .blur:
            // Blur a quarter-size copy and scale it back: same look, a fraction of the work.
            let scale: CGFloat = 0.25
            let radius = 4 + effect.blurAmount * 26
            return camera
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .clampedToExtent()
                .applyingGaussianBlur(sigma: radius)
                .transformed(by: CGAffineTransform(scaleX: 1 / scale, y: 1 / scale))
                .cropped(to: camera.extent)
        case .color:
            let c = effect.color + [0, 0, 0]
            return CIImage(color: CIColor(red: c[0], green: c[1], blue: c[2])).cropped(to: camera.extent)
        case .photo:
            if backdropSize != size, let source = photoSource {
                backdrop = Self.aspectFill(source, to: size)
                backdropSize = size
            }
            return backdrop ?? CIImage(color: .black).cropped(to: camera.extent)
        }
    }

    private var photoSource: CIImage?

    private func loadPhoto() {
        photoSource = CIImage(contentsOf: BackgroundEffect.photoURL, options: [.applyOrientationProperty: true])
        backdrop = nil
        backdropSize = .zero
    }

    private static func aspectFill(_ image: CIImage, to size: CGSize) -> CIImage {
        let extent = image.extent
        guard extent.width > 0, extent.height > 0 else { return image }
        let scale = max(size.width / extent.width, size.height / extent.height)
        let scaled = image.transformed(by: CGAffineTransform(translationX: -extent.minX, y: -extent.minY).scaledBy(x: scale, y: scale))
        let dx = (scaled.extent.width - size.width) / 2, dy = (scaled.extent.height - size.height) / 2
        // Render once so later frames reuse the pixels instead of rescaling the photo every frame.
        return scaled.transformed(by: CGAffineTransform(translationX: -dx, y: -dy))
            .cropped(to: CGRect(origin: .zero, size: size))
            .insertingIntermediate(cache: true)
    }

    private func makeBuffer(size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: Int(size.width),
                kCVPixelBufferHeightKey as String: Int(size.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey as String: true,
            ]
            // A few spare buffers, because the encoder and the preview hold on to frames for a moment.
            let poolAttributes: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 8]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as CFDictionary, attributes as CFDictionary, &newPool)
            pool = newPool
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        if let buffer {
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, .shouldPropagate)
        }
        return buffer
    }

    private static func sampleBuffer(with pixels: CVPixelBuffer, timedLike original: CMSampleBuffer) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(original, at: 0, timingInfoOut: &timing) == noErr else { return nil }
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format) == noErr,
              let format else { return nil }
        var result: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
                                                 formatDescription: format, sampleTiming: &timing, sampleBufferOut: &result)
        return result
    }
}

/// Shows the processed frames while an effect is on (the normal preview shows the raw camera).
struct EffectPreview: UIViewRepresentable {
    let camera: CameraController
    let mirrored: Bool

    func makeUIView(context: Context) -> DisplayView {
        let view = DisplayView()
        view.backgroundColor = .black
        view.displayLayer.videoGravity = .resizeAspectFill
        camera.setEffectPreview(view.displayLayer)
        return view
    }

    func updateUIView(_ uiView: DisplayView, context: Context) {
        uiView.transform = mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity
    }

    static func dismantleUIView(_ uiView: DisplayView, coordinator: ()) {
        uiView.displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
    }

    final class DisplayView: UIView {
        override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }
        var displayLayer: AVSampleBufferDisplayLayer { layer as! AVSampleBufferDisplayLayer }
    }
}

/// Pick blur, a color or a photo for behind you.
struct BackgroundPickerView: View {
    @ObservedObject var settings: RecorderSettings
    let struggling: Bool
    let onPhotoChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var photoItem: PhotosPickerItem?
    @State private var hasPhoto = FileManager.default.fileExists(atPath: BackgroundEffect.photoURL.path)
    @State private var photoError: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Background", selection: $settings.background.kind) {
                        ForEach(BackgroundEffect.Kind.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Works out where you are in each frame and changes everything behind you, live, so no green screen is needed. It records into the take; there's no undo later. Best with you well lit and in front of a tidy background.")
                }

                switch settings.background.kind {
                case .off:
                    EmptyView()
                case .blur:
                    Section("Blur") {
                        Slider(value: $settings.background.blurAmount, in: 0...1) {
                            Text("Strength")
                        } minimumValueLabel: { Image(systemName: "circle.dashed") } maximumValueLabel: { Image(systemName: "circle.fill") }
                    }
                case .color:
                    Section {
                        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 4), spacing: 12) {
                            ForEach(BackgroundEffect.swatches, id: \.self) { rgb in
                                Button { settings.background.color = rgb } label: {
                                    Circle()
                                        .fill(Color(red: rgb[0], green: rgb[1], blue: rgb[2]))
                                        .frame(width: 44, height: 44)
                                        .overlay(Circle().stroke(settings.background.color == rgb ? Theme.accent : Color.white.opacity(0.3), lineWidth: settings.background.color == rgb ? 3 : 1))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                        .padding(.vertical, 6)
                    } header: {
                        Text("Color")
                    } footer: {
                        Text("The first two are chroma green and blue, if you want to key in a background in another app later.")
                    }
                case .photo:
                    Section {
                        PhotosPicker(selection: $photoItem, matching: .images) {
                            Label(hasPhoto ? "Choose another photo" : "Choose a photo", systemImage: "photo")
                        }
                        if let photoError { Text(photoError).font(.footnote).foregroundStyle(.red) }
                    } footer: {
                        Text(hasPhoto ? "The photo fills the frame behind you." : "Pick a photo to put behind you.")
                    }
                }

                if struggling && settings.background.isOn {
                    Section {
                        Label("This phone is working hard to keep up at \(settings.quality.rawValue). If the video stutters, record at 1080p with the effect on.", systemImage: "gauge.with.dots.needle.67percent")
                            .font(.footnote)
                    }
                }
            }
            .navigationTitle("Background")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .onChange(of: photoItem) { _, item in
                guard let item else { return }
                Task { await savePhoto(item) }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @MainActor
    private func savePhoto(_ item: PhotosPickerItem) async {
        photoError = nil
        guard let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) else {
            photoError = "That photo couldn't be opened."
            return
        }
        // Cap at 4K on the long side; bigger only costs memory.
        let maxSide: CGFloat = 3840
        let scale = min(1, maxSide / max(image.size.width, image.size.height))
        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let resized = UIGraphicsImageRenderer(size: size, format: format).image { _ in image.draw(in: CGRect(origin: .zero, size: size)) }
        guard let jpeg = resized.jpegData(compressionQuality: 0.9), (try? jpeg.write(to: BackgroundEffect.photoURL, options: .atomic)) != nil else {
            photoError = "That photo couldn't be saved."
            return
        }
        hasPhoto = true
        onPhotoChanged()
    }
}
