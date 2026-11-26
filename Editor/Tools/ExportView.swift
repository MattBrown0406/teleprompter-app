import SwiftUI
import UIKit

struct ExportView: View {
    @ObservedObject var session: EditorSession
    @Environment(\.dismiss) private var dismiss
    @StateObject private var exporter = Exporter()
    @State private var quality: ExportQuality
    @State private var codec: ExportCodec
    @State private var formats: Set<CanvasFormat>
    @State private var reframe: Bool
    @State private var analysing = false
    @State private var analyseProgress = 0.0
    @State private var saved: Set<String> = []
    @State private var saveError: String?
    @State private var planning = false

    init(session: EditorSession) {
        _session = ObservedObject(wrappedValue: session)
        let p = session.project
        _quality = State(initialValue: p.quality)
        _codec = State(initialValue: p.quality == .uhd4K ? .hevc : .h264)
        _formats = State(initialValue: [p.canvas])
        _reframe = State(initialValue: p.autoReframe ?? true)
    }

    private var project: EditProject { session.project }
    private var ordered: [CanvasFormat] { CanvasFormat.allCases.filter { formats.contains($0) } }

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
                    LabeledContent("Frame rate", value: "30 fps")
                    LabeledContent("Length", value: project.duration.timecode)
                    LabeledContent("About", value: estimate)
                } footer: {
                    Text("1080p is what TikTok, Reels and Facebook play back. 4K keeps more detail if the platform re-compresses or for YouTube.")
                }

                Section {
                    ForEach(CanvasFormat.allCases) { f in
                        Toggle(isOn: Binding(get: { formats.contains(f) }, set: { on in
                            if on { formats.insert(f) } else if formats.count > 1 { formats.remove(f) }
                        })) {
                            VStack(alignment: .leading) {
                                Text(f.label)
                                let s = f.renderSize(quality)
                                Text("\(Int(s.width)) × \(Int(s.height))").font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("Keep my face centred", isOn: $reframe)
                    if analysing { ProgressView("Finding your face…", value: analyseProgress) }
                } header: {
                    Text("Post everywhere")
                } footer: {
                    Text("Pick several shapes to get one video for each platform from the same edit. With face centring on, the crop follows you instead of cutting you off.")
                }

                Section {
                    if exporter.isExporting {
                        VStack(alignment: .leading, spacing: 8) {
                            ProgressView(value: exporter.progress)
                            HStack {
                                Text("Exporting \(exporter.stage) \(Int(exporter.progress * 100))%").font(.caption.monospacedDigit())
                                Spacer()
                                Button("Cancel", role: .destructive) { exporter.cancel() }
                            }
                        }
                    } else if !exporter.outputs.isEmpty {
                        ForEach(exporter.outputs) { out in
                            HStack {
                                Text(out.format.rawValue).font(.headline).frame(width: 50, alignment: .leading)
                                Button {
                                    Task {
                                        do { try await Exporter.saveToPhotos(out.url); saved.insert(out.id) } catch { saveError = error.localizedDescription }
                                    }
                                } label: {
                                    Label(saved.contains(out.id) ? "Saved" : "Save to Photos",
                                          systemImage: saved.contains(out.id) ? "checkmark.circle.fill" : "square.and.arrow.down")
                                }
                                .disabled(saved.contains(out.id))
                                .buttonStyle(.borderless)
                                Spacer()
                                ShareLink(item: out.url) { Image(systemName: "square.and.arrow.up") }
                                    .buttonStyle(.borderless)
                            }
                        }
                        if exporter.outputs.count > 1 {
                            Button("Save all to Photos") {
                                Task {
                                    for out in exporter.outputs where !saved.contains(out.id) {
                                        do { try await Exporter.saveToPhotos(out.url); saved.insert(out.id) } catch { saveError = error.localizedDescription; break }
                                    }
                                }
                            }
                        }
                        Button { planning = true } label: { Label("Add to post calendar", systemImage: "calendar.badge.plus") }
                        if let copy = project.postCopy {
                            Button { UIPasteboard.general.string = copy } label: { Label("Copy post caption and hashtags", systemImage: "doc.on.doc") }
                        }
                    } else {
                        Button { start() } label: {
                            Text(ordered.count > 1 ? "Export \(ordered.count) videos" : "Export video").font(.headline).frame(maxWidth: .infinity)
                        }
                        .disabled(analysing)
                    }
                    if let e = exporter.error ?? saveError { Text(e).foregroundStyle(.red).font(.footnote) }
                }
            }
            .navigationTitle("Export")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { exporter.cancel(); dismiss() } } }
            .onChange(of: quality) { _, _ in reset() }
            .onChange(of: codec) { _, _ in reset() }
            .onChange(of: formats) { _, _ in reset() }
            .onChange(of: reframe) { _, _ in reset() }
            .interactiveDismissDisabled(exporter.isExporting || analysing)
            .sheet(isPresented: $planning) { AddToCalendarSheet(project: session.project, outputs: exporter.outputs) }
        }
    }

    private func reset() { exporter.outputs = []; saved = [] }

    private func start() {
        Task {
            if reframe != (project.autoReframe == true) || (reframe && session.needsFaceAnalysis) {
                analysing = true
                await session.setAutoReframe(reframe) { p in analyseProgress = p }
                analysing = false
            }
            await exporter.export(session.project, formats: ordered, quality: quality, codec: codec)
            if !exporter.outputs.isEmpty && exporter.error == nil { session.markFinished() }
        }
    }

    private var estimate: String {
        // Rough: export presets land near these bitrates.
        let mbps: Double = switch (quality, codec) {
        case (.hd1080, .h264): 16
        case (.hd1080, .hevc): 9
        case (.uhd4K, .h264): 50
        case (.uhd4K, .hevc): 30
        }
        let mb = mbps * project.duration / 8 * Double(max(1, formats.count))
        return mb < 1000 ? "\(Int(mb.rounded())) MB" : String(format: "%.1f GB", mb / 1000)
    }
}
