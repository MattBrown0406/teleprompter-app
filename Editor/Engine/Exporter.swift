import AVFoundation
import Photos
import UIKit

enum ExportCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"
    var id: String { rawValue }
    var note: String { self == .h264 ? "Plays everywhere" : "Half the file size" }
}

/// Renders a project to an .mp4 at 1080p or 4K, 30 fps.
@MainActor
final class Exporter: ObservableObject {
    @Published var progress: Double = 0
    @Published var isExporting = false
    @Published var outputURL: URL?
    @Published var error: String?
    private var session: AVAssetExportSession?

    func export(_ project: EditProject, quality: ExportQuality, codec: ExportCodec) async {
        isExporting = true
        progress = 0
        error = nil
        outputURL = nil
        // A long 4K export can outlast auto-lock, and a locked phone stops the export.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isExporting = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        do {
            var p = project
            p.quality = quality
            let built = try await CompositionBuilder.build(p)
            // HighestQuality presets honour the video composition's renderSize (the fixed-size
            // presets can letterbox vertical canvases), so the canvas size is exact.
            let preset = codec == .hevc ? AVAssetExportPresetHEVCHighestQuality : AVAssetExportPresetHighestQuality
            guard let s = AVAssetExportSession(asset: built.composition, presetName: preset) else {
                throw EditorError.exportFailed("This iPhone can't export at \(quality.rawValue).")
            }
            let url = MediaLibrary.exports.appendingPathComponent(safeName(p.name)).appendingPathExtension("mp4")
            try? FileManager.default.removeItem(at: url)
            s.outputURL = url
            s.outputFileType = .mp4
            s.videoComposition = built.videoComposition
            s.audioMix = built.audioMix
            s.audioTimePitchAlgorithm = .spectral
            s.shouldOptimizeForNetworkUse = true
            session = s

            let poll = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 150_000_000)
                    self?.progress = Double(s.progress)
                }
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                s.exportAsynchronously { c.resume() }
            }
            poll.cancel()
            switch s.status {
            case .completed:
                progress = 1
                outputURL = url
            case .cancelled:
                throw EditorError.cancelled
            default:
                throw EditorError.exportFailed(s.error?.localizedDescription ?? "Export failed.")
            }
        } catch EditorError.cancelled {
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func cancel() { session?.cancelExport() }

    private func safeName(_ s: String) -> String {
        let cleaned = s.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: " -_")).inverted).joined()
        return cleaned.isEmpty ? "Cueframe export" : cleaned
    }

    static func saveToPhotos(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            throw EditorError.exportFailed("Allow Cueframe to add to Photos in Settings to save videos.")
        }
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
