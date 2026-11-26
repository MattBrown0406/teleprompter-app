# Recorder

The Record tab of Cueframe (placeholder name): a teleprompter camera for 9:16 and 16:9 video at 1080p or 4K, 30 fps.

| File | What it does |
| --- | --- |
| RecorderRootView.swift | The screen: camera, script, controls, countdown, remote keys, take review hand-off |
| CameraController.swift | AVCaptureSession, picks a 1080p/4K format locked to 30 fps, rotation, start/pause/resume/stop |
| MovieWriter.swift | AVAssetWriter to .mp4, removes paused gaps so a take with pauses plays as one clip |
| CameraPreview.swift | Live preview layer and the thirds grid |
| PrompterEngine.swift | Frame-by-frame script scroll (CADisplayLink) |
| TeleprompterView.swift | The script overlay: tap to pause, drag to scroll, pinch to resize, mirror; countdown overlay |
| ScriptStore.swift / ScriptLibraryView.swift | Saved scripts (Documents/Scripts.json), write, paste, import .txt/.rtf |
| TakeReviewView.swift | Play back a take; save to Photos, share, edit, retake |
| RecorderSettings.swift / RecorderSettingsView.swift | Saved preferences |

How it records
- Takes are written to `MediaLibrary.recordings` as .mp4, HEVC by default (H.264 in settings). 1080p is about 11 Mbps HEVC / 16 Mbps H.264, 4K about 35 / 50 Mbps.
- Frames are rotated by the capture connection so files are stored upright: 1080x1920 or 2160x3840 for 9:16, the swap for 16:9.
- The shape of the take follows how the phone is held. The record button stays disabled with a hint until the phone matches the chosen 9:16 or 16:9.
- Front camera: preview is mirrored like a selfie, the saved video is not (like the iPhone Camera app).
- If the camera has no 4K at 30 fps, it falls back to 1080p and says so in settings.
- Leaving the app while recording stops and keeps the take.
- A phone call, Siri or another app taking the camera also stops and keeps the take (no frozen gap).
- Recording won't start with less than about 500 MB free, since a full disk loses the whole take.
- The camera is switched off while a take is reviewed, and playback uses the speaker even on silent.

Hand-off: "Edit" calls `EditorLauncher.open(urls:canvas:quality:)` after the review closes.

Not yet tested on a device. Needs to be built in Xcode (or CI) and tried on an iPhone.
