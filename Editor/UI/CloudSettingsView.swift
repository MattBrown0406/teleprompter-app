import SwiftUI

/// Cloud backup: what is backed up, footage options, and email sign-in for moving to a new phone.
struct CloudSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var projects = ProjectSync.shared
    @ObservedObject private var footage = FootageSync.shared
    @State private var email: String?
    @State private var emailField = ""
    @State private var code = ""
    @State private var codeSent = false
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                if SupabaseConfig.current == nil {
                    Section { Text("Cloud backup isn't set up in this build.") }
                } else {
                    Section {
                        LabeledContent("Projects", value: projectsText)
                        LabeledContent("Footage", value: footageText)
                        if footage.backedUpBytes > 0 {
                            LabeledContent("In the cloud", value: ByteCountFormatter.string(fromByteCount: footage.backedUpBytes, countStyle: .file))
                        }
                    } header: {
                        Text("Backup")
                    }

                    Section {
                        Toggle("Back up footage", isOn: $footage.enabled)
                        Toggle("Use cellular data", isOn: $footage.useCellular)
                            .disabled(!footage.enabled)
                    } footer: {
                        Text("Uploads your takes, clips, music and voiceovers so a project can be fully restored. 4K is about 260 to 375 MB a minute, so it waits for Wi-Fi unless you allow cellular.")
                    }

                    accountSection
                }
            }
            .navigationTitle("Cloud backup")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .task { email = await SupabaseClient.shared.email }
        }
    }

    @ViewBuilder private var accountSection: some View {
        Section {
            if let email {
                LabeledContent("Signed in as", value: email)
                Button("Sign out", role: .destructive) {
                    Task {
                        await SupabaseClient.shared.signOut()
                        self.email = nil
                        ProjectSync.shared.syncSoon(delay: 0)
                    }
                }
            } else if !codeSent {
                TextField("Email", text: $emailField)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                Button("Email me a sign-in code") { sendCode() }
                    .disabled(busy || !emailField.contains("@"))
            } else {
                TextField("Code from the email", text: $code)
                    .textContentType(.oneTimeCode)
                    .keyboardType(.numberPad)
                Button("Sign in") { verify() }
                    .disabled(busy || code.count < 6)
                Button("Use a different email") { codeSent = false; code = "" }
            }
            if busy { ProgressView() }
            if let error { Text(error).font(.footnote).foregroundStyle(.red) }
        } header: {
            Text("Account")
        } footer: {
            Text(email == nil
                 ? "Backups are tied to this phone until you sign in. Sign in with the same email on a new phone to get your projects and footage back."
                 : "Sign in with this email on another phone to restore everything. Signing out keeps everything on this phone.")
        }
    }

    private var projectsText: String {
        switch projects.status {
        case .off: return "Off"
        case .idle, .syncing: return "Backing up…"
        case .synced: return "Backed up"
        case .waiting(let why): return why
        }
    }

    private var footageText: String {
        switch footage.status {
        case .off: return "Off"
        case .idle: return footage.pendingCount > 0 ? "\(footage.pendingCount) to go" : "Waiting"
        case .working(let what): return what
        case .done: return "Backed up"
        case .waiting(let why): return why
        }
    }

    private func sendCode() {
        busy = true; error = nil
        let address = emailField.trimmingCharacters(in: .whitespaces).lowercased()
        Task {
            do { try await SupabaseClient.shared.sendCode(to: address); codeSent = true }
            catch { self.error = error.localizedDescription }
            busy = false
        }
    }

    private func verify() {
        busy = true; error = nil
        let address = emailField.trimmingCharacters(in: .whitespaces).lowercased()
        let token = code.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await SupabaseClient.shared.verify(email: address, code: token)
                email = await SupabaseClient.shared.email ?? address
                codeSent = false; code = ""
                // New account: upload what's here, then bring down what's there.
                ProjectSync.shared.syncSoon(delay: 0)
            } catch {
                self.error = "That code didn't work. Check it, or send a new one. (\(error.localizedDescription))"
            }
            busy = false
        }
    }
}
