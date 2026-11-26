import SwiftUI
import PhotosUI

/// The Edit tab: your projects, plus starting a new edit from Photos.
struct ProjectsView: View {
    @EnvironmentObject var router: AppRouter
    @ObservedObject private var store = ProjectStore.shared
    @State private var pickerItems: [PhotosPickerItem] = []
    @State private var showPicker = false
    @State private var newCanvas: CanvasFormat = .vertical
    @State private var importing = false
    @State private var renaming: EditProject?
    @State private var newName = ""
    @State private var showBrand = false
    @State private var showAI = false

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 14)]

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    newProjectCard
                    if !store.projects.isEmpty {
                        Text("Projects").font(.headline).foregroundStyle(Theme.textDim)
                        LazyVGrid(columns: columns, spacing: 14) {
                            ForEach(store.projects) { project in
                                ProjectCard(project: project)
                                    .onTapGesture { router.openProject = project }
                                    .contextMenu {
                                        Button("Rename", systemImage: "pencil") { newName = project.name; renaming = project }
                                        Button("Duplicate", systemImage: "plus.square.on.square") { store.duplicate(project) }
                                        Button("Delete", systemImage: "trash", role: .destructive) { store.delete(project) }
                                    }
                            }
                        }
                    }
                }
                .padding(16)
            }
            .background(Theme.background)
            .navigationTitle("Edit")
            .toolbar {
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button { showBrand = true } label: { Image(systemName: "seal") }
                        .accessibilityLabel("Brand kit")
                    Button { showAI = true } label: { Image(systemName: "sparkles") }
                        .accessibilityLabel("AI settings")
                }
            }
            .sheet(isPresented: $showBrand) { BrandKitView() }
            .sheet(isPresented: $showAI) { AISettingsView() }
            .overlay { if importing { ProgressView("Importing…").padding(24).background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
            .photosPicker(isPresented: $showPicker, selection: $pickerItems, maxSelectionCount: 30,
                          selectionBehavior: .ordered, matching: .videos, preferredItemEncoding: .current)
            .onChange(of: pickerItems) { _, items in
                guard !items.isEmpty else { return }
                importing = true
                Task {
                    let urls = await MediaImport.movies(from: items)
                    importing = false
                    pickerItems = []
                    if !urls.isEmpty { EditorLauncher.open(urls: urls, canvas: newCanvas) }
                }
            }
            .alert("Rename project", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $newName)
                Button("Save") {
                    if var p = renaming { p.name = newName; store.save(p) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
    }

    private var newProjectCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("New edit").font(.title3.bold())
            Picker("Canvas", selection: $newCanvas) {
                ForEach(CanvasFormat.allCases) { Text($0.shortLabel).tag($0) }
            }
            .pickerStyle(.segmented)
            Text(newCanvas.label).font(.footnote).foregroundStyle(Theme.textDim)
            Button {
                showPicker = true
            } label: {
                Label("Choose videos", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(Theme.accent, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.black)
            }
        }
        .padding(16)
        .background(Theme.panel, in: RoundedRectangle(cornerRadius: 18))
    }
}

struct ProjectCard: View {
    let project: EditProject

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .bottomLeading) {
                if let first = project.clips.first {
                    ThumbnailImage(path: first.path, seconds: first.trimStart + 0.2)
                } else {
                    Theme.panelRaised
                }
                Text(project.duration.timecode)
                    .font(.caption2.monospacedDigit().bold())
                    .padding(.horizontal, 6).padding(.vertical, 3)
                    .background(.black.opacity(0.6), in: Capsule())
                    .padding(6)
            }
            .aspectRatio(project.canvas.aspect > 1 ? 16.0 / 9.0 : 3.0 / 4.0, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            Text(project.name).font(.subheadline.weight(.semibold)).lineLimit(1)
            Text("\(project.canvas.shortLabel) · \(project.quality.rawValue)").font(.caption).foregroundStyle(Theme.textDim)
        }
    }
}
