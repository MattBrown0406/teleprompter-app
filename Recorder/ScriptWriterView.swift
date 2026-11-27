import SwiftUI

/// Turns a topic or rough notes into a tight 30, 60 or 90 second script with a hook up front,
/// using the AI provider and key set in AI settings.
struct ScriptWriterView: View {
    /// Notes to start from, e.g. the script being edited.
    var initialNotes: String = ""
    var onUse: (Script) -> Void

    @ObservedObject private var ai = AIClient.shared
    @Environment(\.dismiss) private var dismiss

    @State private var notes = ""
    @State private var length: ScriptLength = .sixty
    @State private var tone: ScriptTone = .conversational
    @State private var draft: ScriptDraft?
    @State private var working = false
    @State private var errorText: String?
    @State private var showKeySettings = false
    @FocusState private var notesFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                if !ai.isConfigured {
                    Section {
                        Button { showKeySettings = true } label: {
                            Label("Add your Anthropic or OpenAI key to use the script helper", systemImage: "key.fill")
                        }
                    }
                }

                Section {
                    TextEditor(text: $notes)
                        .frame(minHeight: 120)
                        .focused($notesFocused)
                } header: {
                    Text("Topic or notes")
                } footer: {
                    Text("A topic (\"3 mistakes new runners make\") or your rough notes. The more detail, the more it sounds like you.")
                }

                Section("Script") {
                    Picker("Length", selection: $length) {
                        ForEach(ScriptLength.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Tone", selection: $tone) {
                        ForEach(ScriptTone.allCases) { Text($0.label).tag($0) }
                    }
                }

                Section {
                    Button(action: generate) {
                        HStack {
                            if working { ProgressView().padding(.trailing, 6) }
                            Text(working ? "Writing" : draft == nil ? "Write script" : "Write another version")
                                .fontWeight(.semibold)
                        }
                    }
                    .disabled(working || !ai.isConfigured || notes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }

                if let errorText {
                    Section { Text(errorText).foregroundStyle(.red).font(.footnote) }
                }

                if let draft {
                    Section {
                        Text(draft.title).font(.headline)
                        Text(draft.body).textSelection(.enabled)
                    } header: {
                        Text("Draft")
                    } footer: {
                        let script = Script(title: draft.title, body: draft.body)
                        Text("\(script.wordCount) words · about \(RecorderFormat.time(script.estimatedDuration)) to read. Paragraphs become parts if you record in parts.")
                    }
                    Section {
                        Button("Use this script") {
                            onUse(Script(title: draft.title, body: draft.body))
                            dismiss()
                        }
                        .fontWeight(.semibold)
                    }
                }
            }
            .navigationTitle("Script helper")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button { showKeySettings = true } label: { Image(systemName: "key") }
                        .accessibilityLabel("AI settings")
                }
            }
            .sheet(isPresented: $showKeySettings) { AISettingsView() }
            .onAppear {
                if notes.isEmpty { notes = initialNotes }
                if notes.isEmpty { notesFocused = true }
            }
        }
    }

    private func generate() {
        working = true
        errorText = nil
        let request = ScriptPrompt.make(notes: notes, length: length, tone: tone)
        Task { @MainActor in
            defer { working = false }
            do {
                let text = try await ai.complete(system: ScriptPrompt.system, prompt: request, maxTokens: 1500)
                draft = ScriptDraft.parse(text)
            } catch {
                errorText = error.localizedDescription
            }
        }
    }
}

enum ScriptLength: Int, CaseIterable, Identifiable {
    case thirty = 30, sixty = 60, ninety = 90
    var id: Int { rawValue }
    var label: String { "\(rawValue) sec" }
    /// Words at a natural 150 words per minute.
    var words: Int { rawValue * 150 / 60 }
}

enum ScriptTone: String, CaseIterable, Identifiable {
    case conversational, energetic, expert, storytelling
    var id: String { rawValue }
    var label: String { rawValue.capitalized }
}

struct ScriptDraft {
    var title: String
    var body: String

    /// Expects "Title: ..." on the first line, then the script. Copes with answers that skip the title.
    static func parse(_ text: String) -> ScriptDraft {
        var lines = text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: "\n")
        var title = "AI script"
        if let first = lines.first, first.lowercased().hasPrefix("title:") {
            title = first.dropFirst("title:".count).trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "\"*")))
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n")
            .replacingOccurrences(of: "**", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ScriptDraft(title: title.isEmpty ? "AI script" : title, body: body)
    }
}

enum ScriptPrompt {
    static let system = """
    You write scripts for short vertical videos (TikTok, Instagram Reels, Facebook) that one person reads aloud from a teleprompter.
    Rules:
    - The first sentence is a hook that makes a scrolling viewer stop within 3 seconds: a bold claim, a surprising fact, a question or a promise. No greetings, no "Hey guys", no "In this video".
    - Write the way people talk: short sentences, everyday words, contractions. Each sentence easy to say in one breath.
    - Split the script into short paragraphs separated by one blank line, one idea per paragraph.
    - End with one clear call to action (follow, comment, save or a next step).
    - Plain spoken text only: no headings, no bullet points, no stage directions, no emojis, no hashtags, no markdown.
    - Stay close to the requested word count.
    - Keep facts from the notes. Don't invent statistics, names or claims.
    Reply with "Title: " and a short title (under 8 words) on the first line, a blank line, then the script and nothing else.
    """

    static func make(notes: String, length: ScriptLength, tone: ScriptTone) -> String {
        """
        Write a \(length.rawValue) second script, about \(length.words) words, in a \(tone.rawValue) tone.

        Topic or notes:
        \(notes.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}
