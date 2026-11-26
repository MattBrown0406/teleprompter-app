import SwiftUI
import WatchConnectivity
import WatchKit

@main
struct CueframeWatchApp: App {
    @StateObject private var link = PhoneLink()

    var body: some Scene {
        WindowGroup {
            RemoteView(link: link)
                .onAppear { link.start() }
        }
    }
}

/// A remote for the iPhone teleprompter: start and stop recording, and control the script.
struct RemoteView: View {
    @ObservedObject var link: PhoneLink

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Button { link.send(.record) } label: {
                    Label(link.status.recording ? "Stop" : "Record",
                          systemImage: link.status.recording ? "stop.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                }
                .tint(.red)

                Button { link.send(.toggleScroll) } label: {
                    Label(link.status.scrolling ? "Pause script" : "Scroll script",
                          systemImage: link.status.scrolling ? "pause.fill" : "play.fill")
                        .frame(maxWidth: .infinity)
                }

                if link.status.recording {
                    Button { link.send(.togglePauseRecording) } label: {
                        Label(link.status.paused ? "Resume take" : "Pause take",
                              systemImage: link.status.paused ? "play.circle" : "pause.circle")
                            .frame(maxWidth: .infinity)
                    }
                }

                HStack {
                    Button { link.send(.rewind) } label: { Image(systemName: "backward.end.fill") }
                        .accessibilityLabel("Back to the start")
                    if !link.status.followsVoice {
                        Button { link.send(.slower) } label: { Image(systemName: "tortoise.fill") }
                            .accessibilityLabel("Slower")
                        Button { link.send(.faster) } label: { Image(systemName: "hare.fill") }
                            .accessibilityLabel("Faster")
                    }
                }

                if let note = link.note {
                    Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
            }
        }
        .navigationTitle("Cueframe")
    }
}

/// Talks to the iPhone app.
final class PhoneLink: NSObject, ObservableObject, WCSessionDelegate {
    @Published var status = RemoteStatus()
    @Published var note: String?

    func start() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ command: RemoteCommand) {
        let session = WCSession.default
        guard session.activationState == .activated, session.isReachable else {
            note = "Open Cueframe's Record tab on your iPhone."
            return
        }
        note = nil
        WKHaptics.click()
        session.sendMessage([RemoteCommand.messageKey: command.rawValue], replyHandler: { reply in
            DispatchQueue.main.async { self.status = RemoteStatus(reply) }
        }, errorHandler: { _ in
            DispatchQueue.main.async { self.note = "Couldn't reach your iPhone. Open Cueframe's Record tab." }
        })
    }

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let context = session.receivedApplicationContext
        DispatchQueue.main.async { if !context.isEmpty { self.status = RemoteStatus(context) } }
    }

    func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        DispatchQueue.main.async { self.status = RemoteStatus(applicationContext) }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard let status = message["status"] as? [String: Any] else { return }
        DispatchQueue.main.async { self.status = RemoteStatus(status) }
    }
}


private enum WKHaptics {
    static func click() { WKInterfaceDevice.current().play(.click) }
}
