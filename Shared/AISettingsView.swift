import SwiftUI

/// Where the user adds their own Anthropic or OpenAI key. Present it in a sheet or push it in a NavigationStack.
struct AISettingsView: View {
    @ObservedObject private var ai = AIClient.shared
    @Environment(\.dismiss) private var dismiss
    @State private var drafts: [AIProvider: String] = [:]
    @State private var models: [AIProvider: String] = [:]
    @State private var status: [AIProvider: String] = [:]
    @State private var testing: AIProvider?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Use", selection: $ai.provider) {
                        ForEach(AIProvider.allCases) { Text($0.label).tag($0) }
                    }
                } footer: {
                    Text("AI writes post captions and hashtags, fixes caption wording, suggests hooks and helps with scripts. It uses your own key, so usage is billed to your account with that company. Nothing is sent until you tap an AI button.")
                }
                ForEach(AIProvider.allCases) { p in
                    Section(p.label) {
                        if ai.hasKey(p) {
                            LabeledContent("API key", value: "Saved on this iPhone")
                            Button("Remove key", role: .destructive) { ai.setKey(nil, for: p); status[p] = nil }
                        } else {
                            SecureField("Paste key (\(p.keyHint))", text: Binding(get: { drafts[p] ?? "" }, set: { drafts[p] = $0 }))
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Save key") {
                                ai.setKey(drafts[p], for: p)
                                drafts[p] = ""
                                if ai.provider != p && !ai.hasKey(ai.provider) { ai.provider = p }
                            }
                            .disabled((drafts[p] ?? "").trimmingCharacters(in: .whitespaces).isEmpty)
                            Link("Get a key", destination: p.consoleURL)
                        }
                        TextField("Model", text: Binding(get: { models[p] ?? ai.model(for: p) },
                                                        set: { models[p] = $0; ai.setModel($0, for: p) }))
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .font(.callout.monospaced())
                        if ai.hasKey(p) {
                            Button {
                                testing = p
                                Task {
                                    do { try await ai.test(p); status[p] = "Key works." } catch { status[p] = error.localizedDescription }
                                    testing = nil
                                }
                            } label: {
                                HStack { Text("Test key"); if testing == p { Spacer(); ProgressView() } }
                            }
                            .disabled(testing != nil)
                        }
                        if let s = status[p] { Text(s).font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }
            .navigationTitle("AI settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}
