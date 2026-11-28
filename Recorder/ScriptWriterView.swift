import SwiftUI

/// Writes a script from a topic, notes or a link, in your voice, at a set length, with a hook,
/// a body and a call to action. Can also turn a script into TikTok, Reel and Facebook versions.
/// Uses the AI provider and key set in AI settings.
struct ScriptWriterView: View {
    /// Saved scripts, for voice examples and for saving platform versions. Nil hides both.
    var store: ScriptStore? = nil
    /// Notes to start from, e.g. the script being edited.
    var initialNotes: String = ""
    var onUse: (Script) -> Void

    @ObservedObject private var ai = AIClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var notes = ""
    @State private var link = ""
    @State private var length: ScriptLength = .sixty
    @State private var tone: ScriptTone = .conversational
    @State private var cta: CallToAction = .auto
    @State private var customCTA = ""
    @State private var useVoice = true
    @State private var voice = VoiceProfile.load()

    @State private var draft: ScriptDraft?
    @State private var hookOptions: [String] = []
    @State private var versions: [PlatformVersion] = []
    @State private var savedVersions = Set<String>()

    @State private var working: Job?
    @State private var errorText: String?
    @State private var showKeySettings = false
    @State private var showVoice = false
    @FocusState private var notesFocused: Bool

    private enum Job { case writing, hooks, versions }

    private var trimmedNotes: String { notes.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var trimmedLink: String { link.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canWrite: Bool { !trimmedNotes.isEmpty || !trimmedLink.isEmpty }
    private var voiceSection: String? {
        useVoice ? voice.promptSection(scripts: store?.scripts ?? []) : nil
    }
    /// What the platform versions are made from: the draft if there is one, else the notes as a finished script.
    private var versionSource: String { draft?.fullText ?? trimmedNotes }

    var body: some View {
        NavigationStack {
            Form {
                if !ai.isConfigured {
                    Section {
                        Button { showKeySettings = true } label: {
                            Label("Add your Anthropic or OpenAI key to use the script writer", systemImage: "key.fill")
                        }
                    }
                }

                inputSection
                optionsSection

                Section {
                    Button(action: write) {
                        HStack {
                            if working == .writing { ProgressView().padding(.trailing, 6) }
                            Text(working == .writing ? (trimmedLink.isEmpty ? "Writing" : "Reading the link and writing")
                                 : draft == nil ? "Write script" : "Write another version")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(working != nil || !ai.isConfigured || !canWrite)
                }

                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
                }

                if let draft { draftSections(draft) }

                versionsSection
            }
            .navigationTitle("Script writer")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showKeySettings = true } label: { Image(systemName: "key") }
                        .accessibilityLabel("AI settings")
                }
            }
            .sheet(isPresented: $showKeySettings) { AISettingsView() }
            .sheet(isPresented: $showVoice) {
                VoiceProfileView(profile: $voice, scripts: store?.scripts ?? [])
            }
            .onAppear {
                if notes.isEmpty { notes = initialNotes }
                if notes.isEmpty { notesFocused = true }
            }
        }
    }

    // MARK: Sections

    private var inputSection: some View {
        Section {
            TextEditor(text: $notes)
                .frame(minHeight: 110)
                .focused($notesFocused)
            HStack {
                Image(systemName: "link").foregroundStyle(Theme.textDim)
                TextField("Link to an article or post (optional)", text: $link)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if trimmedLink.isEmpty && UIPasteboard.general.hasURLs {
                    Button("Paste") { link = UIPasteboard.general.url?.absoluteString ?? UIPasteboard.general.string ?? "" }
                        .font(.footnote.weight(.semibold))
                }
            }
        } header: {
            Text("Topic, notes or a script")
        } footer: {
            Text("A topic (\"3 mistakes new runners make\"), rough notes, a link to write from, or a finished script to turn into platform versions.")
        }
    }

    private var optionsSection: some View {
        Section("Script") {
            Picker("Length", selection: $length) {
                ForEach(ScriptLength.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            Picker("Tone", selection: $tone) {
                ForEach(ScriptTone.allCases) { Text($0.label).tag($0) }
            }
            Picker("Call to action", selection: $cta) {
                ForEach(CallToAction.allCases) { Text($0.label).tag($0) }
            }
            if cta == .custom {
                TextField("e.g. Book a free call at the link in my bio", text: $customCTA, axis: .vertical)
            }
            Toggle(isOn: $useVoice) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Write in my voice")
                    Text(voice.isEmpty ? "Tell it about you first" : voiceSummary)
                        .font(.caption).foregroundStyle(Theme.textDim)
                }
            }
            .disabled(voice.isEmpty)
            Button(voice.isEmpty ? "Set up my voice" : "Edit my voice") { showVoice = true }
        }
    }

    private var voiceSummary: String {
        let count = voice.sampleIDs.filter { id in store?.scripts.contains { $0.id == id } ?? false }.count
        let about = voice.about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : "about you"
        let samples = count == 0 ? nil : "\(count) example script\(count == 1 ? "" : "s")"
        return "Uses " + [about, samples].compactMap { $0 }.joined(separator: " and ")
    }

    @ViewBuilder
    private func draftSections(_ draft: ScriptDraft) -> some View {
        Section {
            Text(draft.title).font(.headline)
        } header: {
            Text("Draft")
        }
        if !draft.hook.isEmpty {
            Section {
                Text(draft.hook).textSelection(.enabled)
                if !hookOptions.isEmpty {
                    ForEach(hookOptions, id: \.self) { option in
                        Button {
                            let old = draft.hook
                            self.draft?.hook = option
                            hookOptions = hookOptions.map { $0 == option ? old : $0 }
                        } label: {
                            HStack(alignment: .top) {
                                Image(systemName: "arrow.triangle.swap").foregroundStyle(Theme.accent)
                                Text(option).foregroundStyle(.primary).multilineTextAlignment(.leading)
                            }
                        }
                    }
                }
                Button(action: moreHooks) {
                    HStack {
                        if working == .hooks { ProgressView().padding(.trailing, 6) }
                        Text(hookOptions.isEmpty ? "Show 3 other hooks" : "Show 3 more")
                    }
                }
                .disabled(working != nil)
            } header: {
                Text("Hook, the first 3 seconds")
            } footer: {
                if !hookOptions.isEmpty { Text("Tap a hook to swap it in.") }
            }
        }
        Section("Body") { Text(draft.body).textSelection(.enabled) }
        if !draft.callToAction.isEmpty {
            Section("Call to action") { Text(draft.callToAction).textSelection(.enabled) }
        }
        Section {
            Button("Use this script") {
                onUse(draft.script)
                dismiss()
            }
            .fontWeight(.semibold)
        } footer: {
            let script = draft.script
            Text("\(script.wordCount) words · about \(RecorderFormat.time(script.estimatedDuration)) to read. Paragraphs become parts if you record in parts.")
        }
    }

    @ViewBuilder
    private var versionsSection: some View {
        let source = versionSource
        if !source.isEmpty {
            Section {
                Button(action: makeVersions) {
                    HStack {
                        if working == .versions { ProgressView().padding(.trailing, 6) }
                        Label(versions.isEmpty ? "Make TikTok, Reel and Facebook versions" : "Make them again",
                              systemImage: "rectangle.stack")
                    }
                }
                .disabled(working != nil || !ai.isConfigured)
                ForEach(versions) { version in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(version.platform.label).font(.subheadline.weight(.bold)).foregroundStyle(Theme.accent)
                            Spacer()
                            let script = version.draft.script
                            Text("\(script.wordCount) words · \(RecorderFormat.time(script.estimatedDuration))")
                                .font(.caption).foregroundStyle(Theme.textDim)
                        }
                        Text(version.draft.fullText).font(.callout).textSelection(.enabled)
                        HStack {
                            if store != nil {
                                Button(savedVersions.contains(version.id) ? "Saved" : "Save") { save(version) }
                                    .disabled(savedVersions.contains(version.id))
                                    .buttonStyle(.bordered)
                            }
                            Button("Use") {
                                onUse(titled(version))
                                dismiss()
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .font(.footnote.weight(.semibold))
                    }
                    .padding(.vertical, 4)
                }
                if store != nil && versions.count > 1 && savedVersions.count < versions.count {
                    Button("Save all \(versions.count) to my scripts") { versions.forEach(save) }
                        .fontWeight(.semibold)
                }
            } header: {
                Text("Platform versions")
            } footer: {
                Text(draft == nil ? "Made from the script in the box above." : "Made from the draft above. Each gets the length, pace and call to action that suits the platform.")
            }
        }
    }

    // MARK: Actions

    private func titled(_ version: PlatformVersion) -> Script {
        let base = draft?.title ?? version.draft.title
        return Script(title: "\(base) · \(version.platform.shortLabel)", body: version.draft.fullText)
    }

    private func save(_ version: PlatformVersion) {
        guard let store, !savedVersions.contains(version.id) else { return }
        store.save(titled(version))
        savedVersions.insert(version.id)
    }

    private func write() {
        working = .writing
        errorText = nil
        let notes = trimmedNotes, linkText = trimmedLink
        let length = length, tone = tone, cta = cta, customCTA = customCTA, voice = voiceSection
        Task { @MainActor in
            defer { working = nil }
            do {
                var page: LinkReader.Page?
                if !linkText.isEmpty {
                    guard let url = LinkReader.url(from: linkText) else { throw LinkReader.Failure.badLink }
                    page = try await LinkReader.read(url)
                }
                let prompt = ScriptPrompt.make(notes: notes, page: page, length: length, tone: tone,
                                               cta: cta, customCTA: customCTA, voice: voice)
                let text = try await ai.complete(system: ScriptPrompt.system, prompt: prompt,
                                                 maxTokens: max(1500, length.words * 4))
                draft = ScriptDraft.parse(text)
                hookOptions = []
                versions = []
                savedVersions = []
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func moreHooks() {
        guard let draft else { return }
        working = .hooks
        errorText = nil
        let voice = voiceSection
        Task { @MainActor in
            defer { working = nil }
            do {
                let text = try await ai.complete(system: ScriptPrompt.hooksSystem,
                                                 prompt: ScriptPrompt.hooks(for: draft, voice: voice), maxTokens: 800)
                let hooks = ScriptPrompt.parseHooks(text)
                if hooks.isEmpty { throw AIError.empty }
                hookOptions = hooks
            } catch {
                errorText = error.localizedDescription
            }
        }
    }

    private func makeVersions() {
        let source = versionSource
        guard !source.isEmpty else { return }
        working = .versions
        errorText = nil
        let voice = voiceSection
        Task { @MainActor in
            defer { working = nil }
            do {
                let text = try await ai.complete(system: ScriptPrompt.versionsSystem,
                                                 prompt: ScriptPrompt.versions(of: source, voice: voice), maxTokens: 3000)
                let parsed = PlatformVersion.parse(text)
                if parsed.isEmpty { throw AIError.empty }
                versions = parsed
                savedVersions = []
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

/// Tell the writer how you talk: a few lines about you, and scripts that sound like you.
struct VoiceProfileView: View {
    @Binding var profile: VoiceProfile
    let scripts: [Script]
    @Environment(\.dismiss) private var dismiss
    @State private var draft = VoiceProfile()

    private var pickable: [Script] {
        scripts.filter { $0.body != ScriptStore.welcome.body && $0.wordCount >= 20 }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextEditor(text: $draft.about).frame(minHeight: 130)
                } header: {
                    Text("About you")
                } footer: {
                    Text("Who you are, who you talk to, how you sound. For example: \"I'm a running coach for busy parents. Straight talking, a bit of humour, no jargon. I say 'folks', never 'guys'.\"")
                }
                Section {
                    if pickable.isEmpty {
                        Text("Scripts you write or paste show up here. Pick up to 3 that sound most like you.")
                            .font(.footnote).foregroundStyle(Theme.textDim)
                    }
                    ForEach(pickable) { script in
                        let picked = draft.sampleIDs.contains(script.id)
                        Button {
                            if picked {
                                draft.sampleIDs.removeAll { $0 == script.id }
                            } else if draft.sampleIDs.count < 3 {
                                draft.sampleIDs.append(script.id)
                            }
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(script.displayTitle).foregroundStyle(.primary)
                                    Text("\(script.wordCount) words").font(.caption).foregroundStyle(Theme.textDim)
                                }
                                Spacer()
                                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked ? Theme.accent : Theme.textDim)
                            }
                        }
                        .disabled(!picked && draft.sampleIDs.count >= 3)
                    }
                } header: {
                    Text("Scripts that sound like you")
                } footer: {
                    Text("The writer copies their rhythm and word choice, not their content. Scripts you wrote yourself work best.")
                }
            }
            .navigationTitle("My voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        draft.sampleIDs = draft.sampleIDs.filter { id in scripts.contains { $0.id == id } }
                        profile = draft
                        draft.save()
                        dismiss()
                    }
                }
            }
            .onAppear { draft = profile }
        }
    }
}
