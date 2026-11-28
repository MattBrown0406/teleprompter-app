import SwiftUI
import UniformTypeIdentifiers

/// Pick, write, paste or import a script.
struct ScriptLibraryView: View {
    @ObservedObject var store: ScriptStore
    /// Starts recording a series of scripts back to back. Nil hides the option.
    var onStartSeries: ((_ ids: [UUID], _ backToBack: Bool) -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var editing: Script?
    @State private var importing = false
    @State private var importError: String?
    @State private var writing = false
    /// A saved script to turn into TikTok, Reel and Facebook versions.
    @State private var adapting: Script?
    @State private var settingUpSeries = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(store.scripts) { script in
                    Button {
                        store.selectedID = script.id
                        dismiss()
                    } label: {
                        HStack(alignment: .firstTextBaseline) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(script.displayTitle).font(.headline).foregroundStyle(.primary)
                                Text("\(script.wordCount) words · about \(RecorderFormat.time(script.estimatedDuration))")
                                    .font(.caption).foregroundStyle(Theme.textDim)
                            }
                            Spacer()
                            if store.selected?.id == script.id {
                                Image(systemName: "checkmark").foregroundStyle(Theme.accent)
                            }
                        }
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { store.delete(script) } label: { Label("Delete", systemImage: "trash") }
                        Button { editing = script } label: { Label("Edit", systemImage: "pencil") }.tint(Theme.accent2)
                    }
                    .contextMenu {
                        Button { editing = script } label: { Label("Edit", systemImage: "pencil") }
                        Button { adapting = script } label: { Label("Make platform versions", systemImage: "rectangle.stack") }
                        Button(role: .destructive) { store.delete(script) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
            }
            .navigationTitle("Scripts")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button { editing = Script(title: "", body: "") } label: { Label("New script", systemImage: "square.and.pencil") }
                        Button { writing = true } label: { Label("Write with AI", systemImage: "sparkles") }
                        Button {
                            let pasted = UIPasteboard.general.string ?? ""
                            editing = Script(title: "", body: pasted)
                        } label: { Label("Paste from clipboard", systemImage: "doc.on.clipboard") }
                        Button { importing = true } label: { Label("Import text file", systemImage: "square.and.arrow.down") }
                        if onStartSeries != nil {
                            Divider()
                            Button { settingUpSeries = true } label: { Label("Record a series", systemImage: "list.number") }
                        }
                    } label: {
                        Image(systemName: "plus")
                    }
                }
            }
            .sheet(item: $editing) { script in
                ScriptEditorView(script: script, store: store) { saved in
                    store.save(saved)
                    store.selectedID = saved.id
                }
            }
            .sheet(isPresented: $settingUpSeries) {
                SeriesSetupView(store: store) { ids, backToBack in
                    // Close the library once the setup sheet is gone, then start.
                    DispatchQueue.main.async {
                        dismiss()
                        onStartSeries?(ids, backToBack)
                    }
                }
            }
            .sheet(isPresented: $writing) {
                ScriptWriterView(store: store) { script in
                    store.save(script)
                    store.selectedID = script.id
                }
            }
            .sheet(item: $adapting) { script in
                ScriptWriterView(store: store, initialNotes: script.body) { made in
                    store.save(made)
                    store.selectedID = made.id
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.plainText, .text, .rtf]) { result in
                importScript(result)
            }
            .alert("Couldn't import", isPresented: Binding(get: { importError != nil }, set: { if !$0 { importError = nil } })) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(importError ?? "")
            }
        }
    }

    private func importScript(_ result: Result<URL, Error>) {
        do {
            let url = try result.get()
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            let text: String
            if url.pathExtension.lowercased() == "rtf" {
                let data = try Data(contentsOf: url)
                text = try NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil).string
            } else {
                // Detects UTF-16 and other encodings that Word and Notes exports use, not just UTF-8.
                var encoding = String.Encoding.utf8
                text = try String(contentsOf: url, usedEncoding: &encoding)
            }
            let script = Script(title: url.deletingPathExtension().lastPathComponent, body: text)
            store.save(script)
            store.selectedID = script.id
        } catch {
            importError = error.localizedDescription
        }
    }
}

struct ScriptEditorView: View {
    @State var script: Script
    var store: ScriptStore? = nil
    var onSave: (Script) -> Void
    @Environment(\.dismiss) private var dismiss
    @FocusState private var bodyFocused: Bool
    @State private var rewriting = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                TextField("Title", text: $script.title)
                    .font(.title3.weight(.semibold))
                    .padding(.horizontal).padding(.vertical, 12)
                Divider()
                TextEditor(text: $script.body)
                    .font(.body)
                    .focused($bodyFocused)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                HStack {
                    Text("\(script.wordCount) words")
                    Spacer()
                    Button { rewriting = true } label: { Label("Tighten with AI", systemImage: "sparkles") }
                        .font(.footnote.weight(.semibold))
                    Spacer()
                    Text("About \(RecorderFormat.time(script.estimatedDuration)) to read")
                }
                .font(.footnote).foregroundStyle(Theme.textDim)
                .padding()
            }
            .background(Theme.background)
            .navigationTitle(script.title.isEmpty ? "New script" : "Edit script")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { onSave(script); dismiss() }
                        .disabled(script.body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { if script.body.isEmpty { bodyFocused = true } }
            .sheet(isPresented: $rewriting) {
                ScriptWriterView(store: store, initialNotes: script.body) { draft in
                    script.body = draft.body
                    if script.title.trimmingCharacters(in: .whitespaces).isEmpty { script.title = draft.title }
                }
            }
        }
    }
}

enum RecorderFormat {
    /// "1:05" style durations.
    static func time(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
