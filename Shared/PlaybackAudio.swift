import AVFoundation

/// Audio setup for watching video back (take review, editor preview).
enum PlaybackAudio {
    /// Plays through the speaker at full volume, even with the ring switch on silent.
    /// Without this the app uses the default category, which the silent switch mutes,
    /// and after recording the camera can leave sound routed to the quiet earpiece.
    static func activate() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        try? session.setActive(true)
    }
}
