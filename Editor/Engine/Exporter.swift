import AVFoundation
import Photos
import UIKit

enum ExportCodec: String, CaseIterable, Identifiable {
    case h264 = "H.264"
    case hevc = "HEVC"
    var id: String { rawValue }
    var note: String { self == .h264 ? "Plays everywhere" : "Half the file size" }
}

struct ExportOutput: Identifiable {
    let format: CanvasFormat
    let url: URL
    /// Which hook version this is ("Hook B"), empty for a single version.
    var label = ""
    var id: String { label + format.rawValue }
    var title: String { label.isEmpty ? format.rawValue : "\(label) \(format.rawValue)" }
}

/// Renders a project to an .mp4 at 1080p or 4K, 30 fps, in one or several canvas shapes.
@MainActor
final class Exporter: ObservableObject {
    @Published var progress: Double = 0
    @Published var isExporting = false
    @Published var outputs: [ExportOutput] = []
    @Published var error: String?
    @Published var stage = ""
    private var session: AVAssetExportSession?
    private var cancelled = false

    var outputURL: URL? { outputs.first?.url }

    /// Exports one file per format. Text and logo positions are relative, so they adapt to each shape.
    func export(_ project: EditProject, formats: [CanvasFormat], quality: ExportQuality, codec: ExportCodec) async {
        await export(versions: [("", project)], formats: formats, quality: quality, codec: codec)
    }

    /// Exports every version (for example each hook) in every format.
    func export(versions: [(label: String, project: EditProject)], formats: [CanvasFormat],
                quality: ExportQuality, codec: ExportCodec) async {
        guard let firstProject = versions.first?.project else { return }
        outputs = []
        error = nil
        cancelled = false
        isExporting = true
        // A long 4K export can outlast auto-lock, and a locked phone stops the export.
        UIApplication.shared.isIdleTimerDisabled = true
        defer {
            isExporting = false
            UIApplication.shared.isIdleTimerDisabled = false
        }
        let list = formats.isEmpty ? [firstProject.canvas] : formats
        let total = list.count * versions.count
        var k = 0
        outer: for version in versions {
            for format in list {
                guard !cancelled else { break outer }
                var p = version.project
                p.canvas = format
                let what = [version.label, list.count > 1 ? format.rawValue : ""].filter { !$0.isEmpty }.joined(separator: " ")
                stage = total > 1 ? "\(what) (\(k + 1) of \(total))" : ""
                let suffix = list.count > 1 ? " " + format.rawValue.replacingOccurrences(of: ":", with: "x") : ""
                if let url = await exportOne(p, quality: quality, codec: codec, suffix: suffix, part: k, of: total) {
                    outputs.append(ExportOutput(format: format, url: url, label: versions.count > 1 ? version.label : ""))
                } else {
                    break outer
                }
                k += 1
            }
        }
        stage = ""
    }

    func export(_ project: EditProject, quality: ExportQuality, codec: ExportCodec) async {
        await export(project, formats: [project.canvas], quality: quality, codec: codec)
    }

    private func exportOne(_ project: EditProject, quality: ExportQuality, codec: ExportCodec,
                           suffix: String, part: Int, of count: Int) async -> URL? {
        progress = Double(part) / Double(count)
        var result: URL?
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
            let url = MediaLibrary.exports.appendingPathComponent(safeName(p.name) + suffix).appendingPathExtension("mp4")
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
                    self?.progress = (Double(part) + Double(s.progress)) / Double(count)
                }
            }
            await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                s.exportAsynchronously { c.resume() }
            }
            poll.cancel()
            switch s.status {
            case .completed:
                progress = Double(part + 1) / Double(count)
                result = url
            case .cancelled:
                throw EditorError.cancelled
            default:
                throw EditorError.exportFailed(s.error?.localizedDescription ?? "Export failed.")
            }
        } catch EditorError.cancelled {
            error = nil
            cancelled = true
        } catch {
            self.error = error.localizedDescription
        }
        return result
    }

    func cancel() { cancelled = true; session?.cancelExport() }

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
