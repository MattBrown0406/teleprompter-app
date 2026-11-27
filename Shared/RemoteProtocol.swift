import Foundation

/// Commands a remote (Apple Watch, headphones, volume buttons, keyboard) can send to the recorder.
/// Shared by the iPhone app and the Watch app, so both agree on the wire format.
enum RemoteCommand: String, CaseIterable {
    case toggleScroll
    case record
    case togglePauseRecording
    case rewind
    case faster
    case slower

    static let messageKey = "command"
}

/// What the recorder is doing, sent to the Watch so its buttons show the right state.
struct RemoteStatus: Equatable {
    var recording = false
    var paused = false
    var scrolling = false
    var followsVoice = false

    var dictionary: [String: Any] {
        ["recording": recording, "paused": paused, "scrolling": scrolling, "followsVoice": followsVoice]
    }

    init() {}

    init(_ dictionary: [String: Any]) {
        recording = dictionary["recording"] as? Bool ?? false
        paused = dictionary["paused"] as? Bool ?? false
        scrolling = dictionary["scrolling"] as? Bool ?? false
        followsVoice = dictionary["followsVoice"] as? Bool ?? false
    }
}
