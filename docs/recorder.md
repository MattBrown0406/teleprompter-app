# Recorder

The Record tab of Cueframe (placeholder name): a teleprompter camera for 9:16 and 16:9 video at 1080p or 4K, 30 fps.

| File | What it does |
| --- | --- |
| RecorderRootView.swift | The screen: camera, script, controls, countdown, remote keys, take review hand-off |
| CameraController.swift | AVCaptureSession, picks a 1080p/4K format locked to 30 fps, rotation, start/pause/resume/stop |
| MovieWriter.swift | AVAssetWriter to .mp4, removes paused gaps so a take with pauses plays as one clip |
| CameraPreview.swift | Live preview layer and the thirds grid |
| PrompterEngine.swift | Frame-by-frame script scroll (CADisplayLink): fixed speed, or gliding to where your voice is |
| ScriptMatcher.swift | Finds your place in the script from the last few words heard (fuzzy, forward only, looks 30 words ahead) |
| SpeechFollower.swift | Speech recognition on the camera's microphone audio, on the phone when supported, restarted every ~50 s |
| RemoteControl.swift | Apple Watch link, headphone play/pause, volume buttons |
| SectionTakes.swift | Record in parts: split at blank lines, takes per part, pick the best, join |
| ScriptWriterView.swift | AI script helper (uses the shared AIClient and the key in AI settings) |
| ../Watch/ | The Apple Watch remote app (CueframeWatch target, embedded in the iPhone app) |
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

Teleprompter
- Follow my voice (on by default): the script moves at your pace and waits when you pause. Words already said are dimmed. Dragging the script or using the arrow keys moves your place too. Needs the microphone and speech recognition permission; if either is off, it falls back to fixed speed or says why.
- Eye-contact layout (on by default): upright, the script is a short band about 3 lines tall and 74% wide right under the lens, read line at the top. Sideways, it is a column a third of the screen wide on the lens side, read line just above the middle, and the controls move to the other side.
- Record in parts: each paragraph is a part. A kept take moves you to the next part. The Takes list lets you star the best take of each part, re-record a part, and join the best takes in the editor.

Remotes
- Apple Watch: record/stop, pause take, scroll/pause script, rewind, speed. Needs the Record tab open on the iPhone.
- AirPods or headphones: play/pause starts or pauses the script.
- Volume up (and Bluetooth selfie remotes, which send volume up): start or stop recording. Volume down: start or pause the script.
- Bluetooth page turners and keyboards: space, arrows and Return as before.

Script helper: Scripts, +, Write with AI (or Tighten with AI in the script editor). Topic or notes in, 30/60/90 seconds and a tone, out comes a script with a hook first, short paragraphs and a call to action. Uses the Anthropic or OpenAI key from AI settings.

Hand-off: "Edit" calls `EditorLauncher.open(urls:canvas:quality:)` after the review closes.

Not yet tested on a device, including voice following, the Watch app, headphone and volume-button remotes. Needs to be built in Xcode (or CI) and tried on an iPhone.
