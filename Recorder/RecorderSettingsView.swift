import SwiftUI

struct RecorderSettingsView: View {
    @ObservedObject var settings: RecorderSettings
    let supports4K: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Quality", selection: $settings.quality) {
                        ForEach(ExportQuality.allCases) { quality in
                            Text(quality.rawValue).tag(quality)
                        }
                    }
                    Picker("Format", selection: $settings.codec) {
                        ForEach(RecordCodec.allCases) { codec in Text(codec.rawValue).tag(codec) }
                    }
                    Picker("Countdown", selection: $settings.countdown) {
                        ForEach(RecorderSettings.countdownChoices, id: \.self) { seconds in
                            Text(seconds == 0 ? "Off" : "\(seconds) seconds").tag(seconds)
                        }
                    }
                    Toggle("Grid", isOn: $settings.showGrid)
                } header: {
                    Text("Video")
                } footer: {
                    Text(videoFooter)
                }

                Section {
                    Toggle("Follow my voice", isOn: $settings.followVoice)
                    Toggle("Eye-contact layout", isOn: $settings.eyeContactLayout)
                    Toggle("Record in parts", isOn: $settings.recordBySection)
                } header: {
                    Text("Teleprompter")
                } footer: {
                    Text("Follow my voice listens as you read and keeps the script at your pace, waiting when you pause. It runs on the phone when the phone supports it. Eye-contact layout puts the script in a narrow band right next to the camera, so you look at the viewer, not the screen. Record in parts splits the script at blank lines: record each part until you're happy, then join the best take of each.")
                }

                Section {
                    Toggle("Mirror text", isOn: $settings.mirrorText)
                    Toggle("Center text", isOn: $settings.centerText)
                    Toggle("Start scrolling when recording starts", isOn: $settings.scrollStartsWithRecording)
                    LabeledContent("Text size") {
                        Stepper("\(Int(settings.fontSize)) pt", value: $settings.fontSize, in: RecorderSettings.fontRange, step: 2)
                    }
                    LabeledContent("Fixed speed") {
                        Stepper("\(Int(settings.scrollSpeed / 10))", value: $settings.scrollSpeed, in: RecorderSettings.speedRange, step: 10)
                    }
                    if !settings.eyeContactLayout {
                        VStack(alignment: .leading) {
                            Text("Script area height")
                            Slider(value: $settings.prompterHeight, in: 0.2...0.7)
                        }
                    }
                    VStack(alignment: .leading) {
                        Text("Background darkness")
                        Slider(value: $settings.prompterOpacity, in: 0...0.9)
                    }
                }

                Section("Remote and keyboard") {
                    Text("A Bluetooth page turner or keyboard works as a remote. Space starts or pauses the scroll, up and down arrows move the script, left and right change the speed, and Return starts or stops recording.")
                        .font(.footnote).foregroundStyle(Theme.textDim)
                }
            }
            .navigationTitle("Recorder settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }

    private var videoFooter: String {
        var text = "All takes record at 30 fps. " + settings.codec.detail
        if !supports4K { text += " This camera can't record 4K at 30 fps, so takes will be 1080p." }
        text += " Mirror text is for glass teleprompter rigs. It only flips the script, never your video."
        return text
    }
}
