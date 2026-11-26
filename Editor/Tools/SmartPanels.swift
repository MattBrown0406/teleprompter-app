import SwiftUI
import UniformTypeIdentifiers
import UIKit

// MARK: Auto-cut

struct AutoCutPanel: View {
    @ObservedObject var session: EditorSession
    @State private var options = AutoCut.Options()
    @State private var cuts: [AutoCut.Cut] = []
    @State private var transcript = ""
    @State private var working = false
    @State private var status = ""
    @State private var progress = 0.0
    @State private var analysed = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if working {
                    ProgressView(value: progress) { Text(status).font(.caption) }
                } else if !analysed {
                    Text("Finds long pauses, dead air, \"um\"s and lines you started again, then cuts them in one tap. You can review each cut first, and undo after.")
                        .font(.caption).foregroundStyle(Theme.textDim)
                    HStack {
                        Text("Pauses over").font(.caption)
                        ForEach([0.5, 0.7, 1.0, 1.5], id: \.self) { v in
                            Chip(selected: options.minPause == v, action: { options.minPause = v }) { Text(String(format: "%.1fs", v)) }
                        }
                    }
                    Toggle("Cut filler words (um, uh)", isOn: $options.cutFillers).font(.caption)
                    Toggle("Cut retakes (lines you started again)", isOn: $options.cutRetakes).font(.caption)
                    Button { run() } label: { accentLabel("Find mistakes") }
                        .disabled(session.project.clips.isEmpty)
                } else if cuts.isEmpty {
                    Text("Nothing to cut. Your take is already tight.").font(.footnote)
                    Button("Search again") { analysed = false }.font(.caption.bold())
                } else {
                    let on = cuts.filter(\.enabled)
                    HStack {
                        Button { apply() } label: {
                            accentLabel("Cut \(on.count) (saves \(String(format: "%.1f", on.reduce(0) { $0 + $1.length })) s)")
                        }
                        .disabled(on.isEmpty)
                        Spacer()
                        Button(on.count == cuts.count ? "None" : "All") {
                            let target = on.count != cuts.count
                            for i in cuts.indices { cuts[i].enabled = target }
                        }
                        .font(.caption.bold())
                    }
                    Text("Tap a row to hear it. Untick anything you want to keep.").font(.caption2).foregroundStyle(Theme.textDim)
                    ForEach($cuts) { $cut in
                        HStack(spacing: 10) {
                            Image(systemName: cut.kind.symbol).frame(width: 20)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(cut.kind.label) · \(String(format: "%.1f", cut.length)) s at \((AutoCut.timelineTime(of: cut, in: session.project) ?? 0).timecode)")
                                    .font(.caption.bold())
                                Text(cut.text).font(.caption2).foregroundStyle(Theme.textDim).lineLimit(1)
                            }
                            Spacer()
                            Toggle("", isOn: $cut.enabled).labelsHidden()
                        }
                        .contentShape(Rectangle())
                        .onTapGesture { preview(cut) }
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
    }

    private func run() {
        working = true
        progress = 0
        session.pause()
        Task {
            do {
                let result = try await AutoCut.analyze(session.project, options: options) { s, p in status = s; progress = p }
                cuts = result.cuts
                transcript = result.transcript
                analysed = true
            } catch {
                session.message = error.localizedDescription
            }
            working = false
        }
    }

    private func preview(_ cut: AutoCut.Cut) {
        guard let t = AutoCut.timelineTime(of: cut, in: session.project) else { return }
        session.pause()
        session.seek(max(0, t - 1.2))
        session.togglePlay()
    }

    private func apply() {
        let chosen = cuts
        let words = transcript
        session.pause()
        session.edit { p in
            AutoCut.apply(chosen, to: &p)
            if !words.isEmpty { p.transcript = words }
        }
        session.message = "Cut \(chosen.filter(\.enabled).count) mistakes. Tap undo to bring them back."
        cuts = []
        analysed = false
    }
}

func accentLabel(_ title: String) -> some View {
    Text(title).font(.subheadline.bold())
        .padding(.horizontal, 18).padding(.vertical, 10)
        .background(Theme.accent, in: Capsule())
        .foregroundStyle(.black)
}

// MARK: Captions and subtitles

struct CaptionsPanel: View {
    @ObservedObject var session: EditorSession
    @StateObject private var scripts = ScriptStore()
    @State private var mode = 0
    @State private var working = false
    @State private var progress = 0.0
    @State private var options = Captioner.Options()
    @State private var scriptChoice = "auto"   // "auto", "none", "project", or a script id

    var body: some View {
        VStack(spacing: 8) {
            Picker("", selection: $mode) {
                Text("Auto captions").tag(0)
                Text("Style").tag(1)
                Text("Subtitles").tag(2)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            ScrollView {
                Group {
                    switch mode {
                    case 0: autoSection
                    case 1: styleSection
                    default: subtitleSection
                    }
                }
                .padding(.horizontal)
                .padding(.bottom)
            }
        }
    }

    // Auto captions from speech, optionally matched to the script.
    private var autoSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(CaptionLook.allCases) { look in
                        Chip(selected: options.look == look, action: {
                            options.look = look
                            options.style = Captioner.style(for: look)
                            if look == .oneWord { options.maxWords = 1 } else if options.maxWords == 1 { options.maxWords = 4 }
                        }) { Text(look.label) }
                    }
                }
            }
            HStack {
                Stepper("Words per caption: \(options.maxWords)", value: $options.maxWords, in: 1...8)
            }
            .font(.caption)
            HStack {
                Toggle("ALL CAPS", isOn: $options.uppercase)
                Picker("Position", selection: $options.y) {
                    Text("Top").tag(0.2)
                    Text("Middle").tag(0.5)
                    Text("Lower").tag(0.7)
                    Text("Bottom").tag(0.84)
                }
            }
            .font(.caption)
            Picker("Exact wording from", selection: $scriptChoice) {
                Text(session.project.scriptText != nil ? "Recorded script" : "No script").tag("auto")
                Text("Speech only").tag("none")
                ForEach(scripts.scripts) { s in Text(s.displayTitle).tag(s.id.uuidString) }
            }
            .font(.caption)
            HStack(spacing: 16) {
                Button { make() } label: {
                    HStack { if working { ProgressView().tint(.black) }; Text(session.captionItems.isEmpty ? "Make captions" : "Redo captions") }
                        .font(.subheadline.bold())
                        .padding(.horizontal, 18).padding(.vertical, 10)
                        .background(Theme.accent, in: Capsule())
                        .foregroundStyle(.black)
                }
                .disabled(working || session.project.clips.isEmpty)
                if working { Text("\(Int(progress * 100))%").font(.caption.monospacedDigit()) }
                if !session.captionItems.isEmpty && !working {
                    Button("Remove") { session.replaceCaptions([]) }.font(.caption.bold()).foregroundStyle(.red)
                }
            }
            Text("Runs on your iPhone. With a script, captions use its exact words and spelling, timed to how you said them.")
                .font(.caption2).foregroundStyle(Theme.textDim)
        }
    }

    private var chosenScript: String? {
        switch scriptChoice {
        case "none": return nil
        case "auto": return session.project.scriptText
        default: return scripts.scripts.first { $0.id.uuidString == scriptChoice }?.body
        }
    }

    private func make() {
        working = true
        progress = 0
        session.pause()
        var opts = options
        opts.script = chosenScript
        Task {
            do {
                let out = try await Captioner.makeCaptions(for: session.project, options: opts) { p in progress = p }
                session.replaceCaptions(out.captions)
                session.applySilently { $0.transcript = out.transcript }
                var note = out.captions.isEmpty ? "No speech found." : "Added \(out.captions.count) captions."
                if let m = out.scriptMatch, opts.script != nil {
                    note += m >= 0.45 ? " Matched to your script." : " The take didn't follow the script, so captions use what you said."
                }
                session.message = note
            } catch {
                session.message = error.localizedDescription
            }
            working = false
        }
    }

    // One style for every caption and subtitle.
    private var styleSection: some View {
        let first = session.captionItems.first
        let style = first?.style ?? options.style
        return VStack(alignment: .leading, spacing: 10) {
            if first == nil {
                Text("Make captions or add a subtitle first, then style them all here.").font(.caption).foregroundStyle(Theme.textDim)
            }
            FontChips(style: style) { font, custom in
                options.style.font = font
                options.style.customFont = custom
                session.editAllCaptions { $0.style.font = font; $0.style.customFont = custom }
            }
            Text("Text colour").font(.caption2).foregroundStyle(Theme.textDim)
            Swatches(color: Binding(get: { style.color }, set: { c in
                options.style.color = c
                session.editAllCaptions("capcolor") { $0.style.color = c }
            }))
            Text("Spoken word colour").font(.caption2).foregroundStyle(Theme.textDim)
            Swatches(color: Binding(get: { style.highlightColor ?? TextOverlay.defaultHighlight }, set: { c in
                options.style.highlightColor = c
                session.editAllCaptions("caphl") { $0.style.highlightColor = c }
            }))
            SliderRow(title: "Size", value: Binding(get: { style.size }, set: { v in
                options.style.size = v
                session.editAllCaptions("capsize") { $0.style.size = v }
            }), range: 0.04...0.16, format: { "\(Int($0 * 1000))" })
            Picker("Background", selection: Binding(get: { style.background }, set: { b in
                options.style.background = b
                session.editAllCaptions { $0.style.background = b }
            })) {
                Text("Plain").tag(TextBackground.none)
                Text("Box").tag(TextBackground.box)
                Text("Pill").tag(TextBackground.pill)
            }
            .pickerStyle(.segmented)
            HStack {
                Toggle("Outline", isOn: Binding(get: { style.outline }, set: { v in
                    options.style.outline = v
                    session.editAllCaptions { $0.style.outline = v }
                }))
                Toggle("Shadow", isOn: Binding(get: { style.shadow }, set: { v in
                    options.style.shadow = v
                    session.editAllCaptions { $0.style.shadow = v }
                }))
            }
            .font(.caption)
            Text("Animation").font(.caption2).foregroundStyle(Theme.textDim)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(CaptionLook.allCases) { look in
                        Chip(selected: (first?.look ?? .plain) == look, action: {
                            session.editAllCaptions { item in
                                item.look = look
                                item.animation = look == .plain ? .pop : .none
                            }
                        }) { Text(look.label) }
                    }
                }
            }
        }
    }

    // Hand-written subtitles: add at the playhead, edit the words, export .srt.
    private var subtitleSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Button {
                    let style = session.captionItems.last?.style ?? Captioner.style(for: .plain)
                    session.addSubtitle(style: style, y: session.captionItems.last?.center.y ?? options.y)
                } label: { Label("Add at playhead", systemImage: "plus") }
                .font(.caption.bold())
                Spacer()
                if !session.captionItems.isEmpty, let url = srtFile() {
                    ShareLink(item: url) { Label(".srt file", systemImage: "square.and.arrow.up") }.font(.caption.bold())
                }
            }
            if session.captionItems.isEmpty {
                Text("Type your own subtitles, or make auto captions and fix the words here.").font(.caption).foregroundStyle(Theme.textDim)
            }
            ForEach(session.captionItems) { item in
                HStack(spacing: 8) {
                    Button { session.seek(item.start); session.selection = .text(item.id) } label: {
                        Text(item.start.timecode).font(.caption2.monospacedDigit()).frame(width: 44, alignment: .leading)
                    }
                    TextField("Subtitle", text: Binding(get: { item.text }, set: { v in
                        session.edit("sub-\(item.id)") { p in
                            if let i = p.texts.firstIndex(where: { $0.id == item.id }) { p.texts[i].text = v }
                        }
                    }))
                    .font(.caption)
                    .textFieldStyle(.roundedBorder)
                    Button { session.edit { $0.texts.removeAll { $0.id == item.id } } } label: {
                        Image(systemName: "minus.circle").foregroundStyle(.red)
                    }
                }
            }
        }
    }

    private func srtFile() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(session.project.name).srt")
        try? Captioner.srt(session.project).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}

/// Built-in font styles plus the brand font, if one was imported.
struct FontChips: View {
    let style: TextStyle
    let pick: (TextFont, String?) -> Void
    @ObservedObject private var brand = BrandStore.shared

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack {
                if let name = brand.kit?.customFontName {
                    Chip(selected: style.customFont == name, action: { pick(brand.kit?.font ?? .bold, name) }) {
                        Text("Brand").font(.custom(name, size: 13))
                    }
                }
                ForEach(TextFont.allCases) { f in
                    Chip(selected: style.customFont == nil && style.font == f, action: { pick(f, nil) }) {
                        Text(f.label).font(Font(TextOverlay.uiFont(f, size: 13) as CTFont))
                    }
                }
            }
        }
    }
}

// MARK: Audio cleanup

struct CleanupPanel: View {
    @ObservedObject var session: EditorSession
    @State private var strength: AudioCleaner.Strength = .standard
    @State private var working = false
    @State private var progress = 0.0

    var body: some View {
        let cleaned = session.project.clips.contains { $0.cleanAudioPath != nil }
        VStack(spacing: 12) {
            Text("Removes background hum, hiss and room noise, and evens out your voice so it's steady and loud enough for phone speakers.")
                .font(.caption).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
            Picker("Strength", selection: $strength) {
                ForEach(AudioCleaner.Strength.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            if working {
                ProgressView(value: progress) { Text("Cleaning…").font(.caption) }
            } else {
                HStack(spacing: 16) {
                    Button { run() } label: { accentLabel(cleaned ? "Clean again" : "Clean up voice") }
                        .disabled(session.project.clips.isEmpty)
                    if cleaned {
                        Button("Use original sound") {
                            session.edit { p in for i in p.clips.indices { p.clips[i].cleanAudioPath = nil } }
                        }
                        .font(.caption.bold())
                    }
                }
            }
            if cleaned { Text("Cleaned sound is on. Play to compare, or undo.").font(.caption2).foregroundStyle(Theme.textDim) }
        }
        .padding(.horizontal)
    }

    private func run() {
        working = true
        progress = 0
        session.pause()
        let paths = Array(Set(session.project.clips.filter { !$0.isBrandClip }.map(\.path)))
        let level = strength
        Task {
            var results: [String: String] = [:]
            for (n, path) in paths.enumerated() {
                do {
                    let out = try await AudioCleaner.clean(MediaLibrary.resolve(path), strength: level) { p in
                        progress = (Double(n) + p) / Double(paths.count)
                    }
                    results[path] = MediaLibrary.relativePath(out)
                } catch {
                    session.message = error.localizedDescription
                }
            }
            if !results.isEmpty {
                session.edit { p in
                    for i in p.clips.indices { if let r = results[p.clips[i].path] { p.clips[i].cleanAudioPath = r } }
                }
                session.message = "Voice cleaned up. Tap undo to compare with the original."
            }
            working = false
        }
    }
}

// MARK: Brand kit

struct BrandPanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var brand = BrandStore.shared
    @State private var parts = BrandKit.Parts()
    @State private var showKit = false

    var body: some View {
        VStack(spacing: 10) {
            if let kit = brand.kit {
                HStack {
                    Toggle("Logo", isOn: $parts.logo).disabled(!kit.hasLogo)
                    Toggle("Text style", isOn: $parts.text)
                }
                .font(.caption)
                HStack {
                    Toggle("Intro", isOn: $parts.intro).disabled(kit.introPath == nil)
                    Toggle("Outro", isOn: $parts.outro).disabled(kit.outroPath == nil)
                }
                .font(.caption)
                HStack(spacing: 16) {
                    Button { session.edit { kit.apply(to: &$0, parts: parts) }; session.message = "Brand applied." } label: {
                        accentLabel("Apply brand")
                    }
                    Button("Remove") { session.edit { BrandKit.remove(from: &$0) } }.font(.caption.bold())
                    Button("Edit kit") { showKit = true }.font(.caption.bold())
                }
            } else {
                Text("Save your logo, colours, font, intro and outro once, then put them on any video in one tap.")
                    .font(.caption).foregroundStyle(Theme.textDim).multilineTextAlignment(.center)
                Button { showKit = true } label: { accentLabel("Set up brand kit") }
            }
        }
        .padding(.horizontal)
        .sheet(isPresented: $showKit) { BrandKitView() }
    }
}

// MARK: AI help

struct AIPanel: View {
    @ObservedObject var session: EditorSession
    @ObservedObject private var ai = AIClient.shared
    @State private var platform: PostCopy.Platform = .tiktok
    @State private var working: String?
    @State private var showSettings = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if !ai.isConfigured {
                    HStack {
                        Text("Add your Anthropic or OpenAI key for AI writing. Hashtags still work without one.")
                            .font(.caption).foregroundStyle(Theme.textDim)
                        Button("Add key") { showSettings = true }.font(.caption.bold())
                    }
                }
                Text("Post caption and hashtags").font(.caption.bold())
                Picker("Platform", selection: $platform) {
                    ForEach(PostCopy.Platform.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                HStack {
                    Button { writePost() } label: { accentLabel(working == "post" ? "Writing…" : "Write post") }
                        .disabled(working != nil)
                    if let copy = session.project.postCopy {
                        Button { UIPasteboard.general.string = copy; session.message = "Copied. Paste it when you post." } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .font(.caption.bold())
                    }
                }
                if session.project.postCopy != nil {
                    TextField("Post", text: Binding(get: { session.project.postCopy ?? "" },
                                                    set: { v in session.edit("post") { $0.postCopy = v } }), axis: .vertical)
                        .lineLimit(3...8)
                        .font(.caption)
                        .padding(8)
                        .background(Theme.panelRaised, in: RoundedRectangle(cornerRadius: 8))
                }
                Divider()
                Text("Edit with AI").font(.caption.bold())
                HStack(spacing: 10) {
                    Button(working == "fix" ? "Fixing…" : "Fix caption words") { fixCaptions() }
                        .disabled(working != nil || session.captionItems.isEmpty || !ai.isConfigured)
                    Button(working == "hook" ? "Writing…" : "Add a hook title") { writeHook() }
                        .disabled(working != nil || !ai.isConfigured)
                }
                .font(.caption.bold())
                Text("Fix caption words corrects misheard words and adds punctuation without changing timing. A hook title is a short line on screen for the first 3 seconds.")
                    .font(.caption2).foregroundStyle(Theme.textDim)
                Button("AI settings") { showSettings = true }.font(.caption2)
            }
            .padding(.horizontal)
            .padding(.bottom)
        }
        .sheet(isPresented: $showSettings) { AISettingsView() }
    }

    private func writePost() {
        working = "post"
        Task {
            do {
                let copy = try await PostCopy.make(for: session.project, platform: platform)
                session.edit { $0.postCopy = copy }
            } catch {
                session.message = error.localizedDescription
            }
            working = nil
        }
    }

    /// Sends caption lines and takes back the same number of corrected lines. Timing stays put.
    private func fixCaptions() {
        working = "fix"
        let items = session.captionItems
        let numbered = items.enumerated().map { "\($0.offset + 1). \($0.element.text)" }.joined(separator: "\n")
        let context = session.project.scriptText.map { "\n\nThe script they were reading (may differ slightly):\n\(String($0.prefix(6000)))" } ?? ""
        Task {
            do {
                let reply = try await AIClient.shared.complete(
                    system: "You correct speech-to-text captions. Fix misheard words, spelling, names and punctuation. Keep the same number of words in each line whenever you can, and keep the speaker's wording. Reply with only the numbered lines, same count and order.",
                    prompt: "Captions:\n\(numbered)\(context)", maxTokens: 8000)
                var fixed: [Int: String] = [:]
                for line in reply.split(separator: "\n") {
                    let parts = line.split(separator: ".", maxSplits: 1)
                    if parts.count == 2, let n = Int(parts[0].trimmingCharacters(in: .whitespaces)) {
                        fixed[n - 1] = parts[1].trimmingCharacters(in: .whitespaces)
                    }
                }
                let upper = items.allSatisfy { $0.text == $0.text.uppercased() }
                session.edit { p in
                    for (k, item) in items.enumerated() {
                        guard var text = fixed[k], !text.isEmpty,
                              let i = p.texts.firstIndex(where: { $0.id == item.id }) else { continue }
                        if upper { text = text.uppercased() }
                        let newWords = text.split(separator: " ").map(String.init)
                        // Same word count keeps the word-by-word timing; otherwise spread the words evenly.
                        if let old = p.texts[i].words, old.count != newWords.count, !newWords.isEmpty {
                            let span = (old.last?.end ?? item.duration) - (old.first?.start ?? 0)
                            let step = span / Double(newWords.count)
                            let s0 = old.first?.start ?? 0
                            p.texts[i].words = newWords.enumerated().map { j, w in
                                CaptionWord(text: w, start: s0 + step * Double(j), end: s0 + step * Double(j + 1))
                            }
                        }
                        p.texts[i].text = text
                    }
                }
                session.message = "Fixed \(fixed.count) captions. Tap undo to go back."
            } catch {
                session.message = error.localizedDescription
            }
            working = nil
        }
    }

    private func writeHook() {
        working = "hook"
        let words = PostCopy.source(session.project)
        Task {
            do {
                let reply = try await AIClient.shared.complete(
                    system: "You write on-screen hook titles for short vertical videos. Reply with one line of at most 7 words, no quotes, no hashtags, no emojis.",
                    prompt: "Write a scroll-stopping hook title for this video:\n\(String(words.prefix(6000)))", maxTokens: 1000)
                let line = reply.split(separator: "\n").first.map(String.init)?
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"' ").union(.whitespaces)) ?? ""
                guard !line.isEmpty else { throw AIError.empty }
                let intro = session.project.clips.first?.role == .intro ? session.project.clips[0].outputDuration : 0
                var item = TextItem(text: line, start: intro, end: min(session.project.duration, intro + 3))
                item.center = NPoint(x: 0.5, y: 0.22)
                item.style.size = 0.08
                item.style.background = .box
                item.animation = .pop
                if let kit = BrandStore.current {
                    item.style.font = kit.font
                    item.style.customFont = kit.customFontName
                    item.style.backgroundColor = RGBA(r: kit.primary.r, g: kit.primary.g, b: kit.primary.b, a: 0.9)
                }
                session.edit { $0.texts.append(item) }
                session.selection = .text(item.id)
            } catch {
                session.message = error.localizedDescription
            }
            working = nil
        }
    }
}
