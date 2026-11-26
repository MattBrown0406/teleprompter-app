import SwiftUI
import PhotosUI
import AVFoundation
import UniformTypeIdentifiers
import UIKit

/// Set up the brand once: logo, colours, font, intro and outro.
struct BrandKitView: View {
    @ObservedObject private var store = BrandStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var kit: BrandKit
    @State private var logoItem: PhotosPickerItem?
    @State private var introItem: PhotosPickerItem?
    @State private var outroItem: PhotosPickerItem?
    @State private var importingFont = false
    @State private var busy = false
    @State private var note: String?

    init() {
        _kit = State(initialValue: BrandStore.shared.kit ?? BrandKit())
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Logo") {
                    HStack {
                        if let path = kit.logoPath, let img = UIImage(contentsOfFile: MediaLibrary.resolve(path).path) {
                            Image(uiImage: img).resizable().scaledToFit().frame(width: 56, height: 56)
                                .background(Color.black.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                        }
                        PhotosPicker(selection: $logoItem, matching: .images) {
                            Text(kit.logoPath == nil ? "Choose logo" : "Change logo")
                        }
                        if kit.logoPath != nil {
                            Spacer()
                            Button("Remove", role: .destructive) { kit.logoPath = nil }
                        }
                    }
                    if kit.logoPath != nil {
                        Picker("Corner", selection: $kit.logoCorner) {
                            ForEach(LogoCorner.allCases) { Text($0.label).tag($0) }
                        }
                        SliderRow(title: "Size", value: $kit.logoSize, range: 0.08...0.4, format: { "\(Int($0 * 100))%" })
                        SliderRow(title: "Opacity", value: $kit.logoOpacity, range: 0.3...1, format: { "\(Int($0 * 100))%" })
                    }
                }
                Section {
                    ColorPicker("Highlight (spoken word)", selection: colorBinding(\.accent), supportsOpacity: false)
                    ColorPicker("Main colour (boxes)", selection: colorBinding(\.primary), supportsOpacity: false)
                    ColorPicker("Text", selection: colorBinding(\.textColor), supportsOpacity: false)
                } header: { Text("Colours") } footer: { Text("These show first in every colour picker in the editor.") }
                Section("Font") {
                    Picker("Style", selection: $kit.font) {
                        ForEach(TextFont.allCases) { Text($0.label).tag($0) }
                    }
                    HStack {
                        Button(kit.customFontName == nil ? "Import font file" : "Change font file") { importingFont = true }
                        if let name = kit.customFontName {
                            Spacer()
                            Text(name).font(.custom(name, size: 15)).lineLimit(1)
                            Button { kit.customFontName = nil; kit.customFontPath = nil } label: { Image(systemName: "xmark.circle.fill") }
                                .buttonStyle(.borderless)
                        }
                    }
                }
                Section {
                    clipRow("Intro", path: kit.introPath, duration: kit.introDuration, item: $introItem) {
                        kit.introPath = nil; kit.introDuration = 0
                    }
                    clipRow("Outro", path: kit.outroPath, duration: kit.outroDuration, item: $outroItem) {
                        kit.outroPath = nil; kit.outroDuration = 0
                    }
                } header: { Text("Intro and outro") } footer: { Text("Short clips (2 to 5 seconds) work best. They play before and after your video.") }
                Section {
                    Toggle("Add to every new video", isOn: $kit.autoApply)
                }
                if let note { Section { Text(note).font(.footnote).foregroundStyle(.secondary) } }
                if store.kit != nil {
                    Section { Button("Delete brand kit", role: .destructive) { store.kit = nil; dismiss() } }
                }
            }
            .disabled(busy)
            .overlay { if busy { ProgressView() } }
            .navigationTitle("Brand kit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { store.kit = kit; dismiss() } }
            }
            .onChange(of: logoItem) { _, item in
                guard let item else { return }
                busy = true
                Task {
                    if let data = try? await item.loadTransferable(type: Data.self), let img = UIImage(data: data),
                       let png = img.pngData() {
                        let url = MediaLibrary.newFile(in: MediaLibrary.media, ext: "png")
                        try? png.write(to: url)
                        kit.logoPath = MediaLibrary.relativePath(url)
                    } else {
                        note = "Couldn't read that image."
                    }
                    logoItem = nil
                    busy = false
                }
            }
            .onChange(of: introItem) { _, item in loadClip(item) { kit.introPath = $0; kit.introDuration = $1; introItem = nil } }
            .onChange(of: outroItem) { _, item in loadClip(item) { kit.outroPath = $0; kit.outroDuration = $1; outroItem = nil } }
            .fileImporter(isPresented: $importingFont, allowedContentTypes: [.font]) { result in
                guard case .success(let url) = result else { return }
                if let font = BrandStore.importFont(from: url) {
                    kit.customFontPath = font.path
                    kit.customFontName = font.name
                } else {
                    note = "That font file couldn't be used. Try a .ttf or .otf file."
                }
            }
        }
    }

    private func colorBinding(_ kp: WritableKeyPath<BrandKit, RGBA>) -> Binding<Color> {
        Binding(get: {
            let c = kit[keyPath: kp]
            return Color(red: c.r, green: c.g, blue: c.b)
        }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
            UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
            kit[keyPath: kp] = RGBA(r: Double(r), g: Double(g), b: Double(b))
        })
    }

    private func clipRow(_ title: String, path: String?, duration: Double, item: Binding<PhotosPickerItem?>,
                         remove: @escaping () -> Void) -> some View {
        HStack {
            if let path {
                ThumbnailImage(path: path, seconds: 0.3).frame(width: 40, height: 56).clipShape(RoundedRectangle(cornerRadius: 6))
            }
            VStack(alignment: .leading) {
                Text(title)
                if path != nil { Text(duration.timecode).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            PhotosPicker(selection: item, matching: .videos) { Text(path == nil ? "Choose" : "Change") }
                .buttonStyle(.borderless)
            if path != nil {
                Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }.buttonStyle(.borderless)
            }
        }
    }

    private func loadClip(_ item: PhotosPickerItem?, done: @escaping (String, Double) -> Void) {
        guard let item else { return }
        busy = true
        Task {
            if let movie = try? await item.loadTransferable(type: PickedMovie.self),
               let d = try? await AVURLAsset(url: movie.url).load(.duration).seconds, d > 0 {
                done(MediaLibrary.relativePath(movie.url), d)
            } else {
                note = "Couldn't read that video."
            }
            busy = false
        }
    }
}
