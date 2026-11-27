import SwiftUI
import Combine
import MediaPlayer
import WatchConnectivity
import AVKit

/// Collects remote commands from the Apple Watch app and from headphone buttons,
/// and keeps the Watch up to date with what the recorder is doing.
///
/// Bluetooth page turners and keyboards are handled by key presses in `RecorderRootView`,
/// and the phone's volume buttons by `VolumeButtonRemote`.
final class RemoteHub: NSObject, ObservableObject {
    /// Called on the main thread for every command.
    var onCommand: ((RemoteCommand) -> Void)?

    @Published private(set) var watchConnected = false

    private var status = RemoteStatus()
    private var commandTargets: [Any] = []

    func start() {
        if WCSession.isSupported() {
            let session = WCSession.default
            session.delegate = self
            session.activate()
        }
        startHeadphoneRemote()
    }

    func stop() {
        let center = MPRemoteCommandCenter.shared()
        for target in commandTargets {
            center.togglePlayPauseCommand.removeTarget(target)
            center.playCommand.removeTarget(target)
            center.pauseCommand.removeTarget(target)
        }
        commandTargets = []
        // Don't leave the teleprompter on the lock screen after leaving the recorder.
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }

    private var scrollWatch: AnyCancellable?

    /// Keeps the Watch's play button in step with the script.
    func observe(_ engine: PrompterEngine) {
        scrollWatch = engine.$isScrolling.removeDuplicates().sink { [weak self] scrolling in
            guard let self else { return }
            var next = self.status
            next.scrolling = scrolling
            self.update(next)
        }
    }

    /// Tell the Watch what the recorder is doing.
    func setRecorder(recording: Bool, paused: Bool, followsVoice: Bool) {
        var next = status
        next.recording = recording
        next.paused = paused
        next.followsVoice = followsVoice
        update(next)
    }

    private func update(_ newStatus: RemoteStatus) {
        guard newStatus != status else { return }
        status = newStatus
        sendStatus()
    }

    private func sendStatus() {
        let newStatus = status
        guard WCSession.isSupported() else { return }
        let session = WCSession.default
        guard session.activationState == .activated, session.isPaired, session.isWatchAppInstalled else { return }
        try? session.updateApplicationContext(newStatus.dictionary)
        if session.isReachable {
            session.sendMessage(["status": newStatus.dictionary], replyHandler: nil, errorHandler: nil)
        }
    }

    /// Play/pause on AirPods and wired headphones starts or pauses the script.
    private func startHeadphoneRemote() {
        guard commandTargets.isEmpty else { return }
        let center = MPRemoteCommandCenter.shared()
        let send: (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus = { [weak self] _ in
            DispatchQueue.main.async { self?.onCommand?(.toggleScroll) }
            return .success
        }
        commandTargets.append(center.togglePlayPauseCommand.addTarget(handler: send))
        commandTargets.append(center.playCommand.addTarget(handler: send))
        commandTargets.append(center.pauseCommand.addTarget(handler: send))
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [MPMediaItemPropertyTitle: "Cueframe teleprompter"]
    }

    private func handle(_ message: [String: Any]) {
        guard let raw = message[RemoteCommand.messageKey] as? String,
              let command = RemoteCommand(rawValue: raw) else { return }
        DispatchQueue.main.async { self.onCommand?(command) }
    }
}

extension RemoteHub: WCSessionDelegate {
    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let connected = activationState == .activated && session.isPaired && session.isWatchAppInstalled
        DispatchQueue.main.async {
            self.watchConnected = connected
            self.sendStatus()
        }
    }

    func sessionDidBecomeInactive(_ session: WCSession) {}

    func sessionDidDeactivate(_ session: WCSession) {
        // Switching to another Watch: start talking to the new one.
        session.activate()
    }

    func sessionWatchStateDidChange(_ session: WCSession) {
        let connected = session.isPaired && session.isWatchAppInstalled
        DispatchQueue.main.async { self.watchConnected = connected }
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        handle(message)
    }

    func session(_ session: WCSession, didReceiveMessage message: [String: Any], replyHandler: @escaping ([String: Any]) -> Void) {
        handle(message)
        DispatchQueue.main.async { replyHandler(self.status.dictionary) }
    }
}

/// The phone's volume buttons as a remote, the way the Camera app uses them.
/// Volume up (also what most Bluetooth selfie remotes send) starts or stops recording.
/// Volume down starts or pauses the script.
struct VolumeButtonRemote: UIViewRepresentable {
    let onCommand: (RemoteCommand) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = true
        view.backgroundColor = .clear
        if #available(iOS 17.2, *) {
            let interaction = AVCaptureEventInteraction(
                primary: { event in
                    if event.phase == .ended { context.coordinator.send(.toggleScroll) }
                },
                secondary: { event in
                    if event.phase == .ended { context.coordinator.send(.record) }
                })
            view.addInteraction(interaction)
        }
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onCommand = onCommand
    }

    func makeCoordinator() -> Coordinator { Coordinator(onCommand: onCommand) }

    final class Coordinator {
        var onCommand: (RemoteCommand) -> Void
        init(onCommand: @escaping (RemoteCommand) -> Void) { self.onCommand = onCommand }
        func send(_ command: RemoteCommand) { onCommand(command) }
    }
}
