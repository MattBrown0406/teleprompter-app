import SwiftUI

struct ExportView: View {
    let project: EditProject
    @Environment(\.dismiss) private var dismiss
    @StateObject private var exporter = Exporter()
    @State private var quality: ExportQuality
    @State private var codec: ExportCodec = .h264
    @State private var saved = false
    @State private var saveError: String?

    init(project: EditProject) {
        self.project = project
        _quality = State(initialValue: project.quality)
        _codec = State(initialValue: project.quality == .uhd4K ? .hevc : .h264)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Resolution", selection: $quality) {
                        ForEach(ExportQuality.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Format", selection: $codec) {
                        ForEach(ExportCodec.allCases) { c in Text("\(c.rawValue)  \(c.note)").tag(c) }
                    }
                    LabeledContent("Size", value: sizeLabel)
                    LabeledContent("Frame rate", value: "30 fps")
                    LabeledContent("Length", value: project.duration.timecode)
                    LabeledContent("About", value: estimate)
                } footer: {
                    Text("1080p is what TikTok, Reels and Facebook play back. 4K keeps more detail if the platform re-compresses or for YouTube.")
                }

                Section {
                    if exporter.isExporting {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: exporter.progress)
                            HStack {
                                Text("Exporting \(Int(exporter.progress * 100))%").font(.caption.monospacedDigit())
                                Spacer()
                                Button("Cancel", role: .destructive) { exporter.cancel() }
                            }
                        }
                    } else if let url = exporter.outputURL {
                        Button {
                            Task {
                                do { try await Exporter.saveToPhotos(url); saved = true } catch { saveError = error.localizedDescription }
                            }
                        } label: {
                            Label(saved ? "Saved to Photos" : "Save to Photos", systemImage: saved ? "checkmark.circle.fill" : "square.and.arrow.down")
                        }
                        .disabled(saved)
                        ShareLink(item: url) { Label("Share to TikTok, Instagram, Facebook…", systemImage: "square.and.arrow.up") }
                    } else {
                        Button {
                            Task { await exporter.export(project, quality: quality, codec: codec) }
                        } label: {
                            Text("Export video").font(.headline).frame(maxWidth: .infinity)
                        }
                    }
                    if let e = exporter.error ?? saveError { Text(e).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { exporter.cancel(); dismiss() } } }
            .onChange(of: quality) { _, _ in exporter.outputURL = nil; saved = false }
            .onChange(of: codec) { _, _ in exporter.outputURL = nil; saved = false }
            .interactiveDismissDisabled(exporter.isExporting)
        }
    }

    private var sizeLabel: String {
        let s = project.canvas.renderSize(quality)
        return "\(Int(s.width)) × \(Int(s.height))"
    }

    private var estimate: String {
        // Rough: export presets land near these bitrates.
        let mbps: Double = switch (quality, codec) {
        case (.hd1080, .h264): 16
        case (.hd1080, .hevc): 9
        case (.uhd4K, .h264): 50
        case (.uhd4K, .hevc): 30
        }
        let mb = mbps * project.duration / 8
        return mb < 1000 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f GB", mb / 1000)
    }
}
