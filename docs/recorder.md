# Recorder

The Record tab of Cueframe (placeholder name): a teleprompter camera for 9:16 and 16:9 video at 1080p or 4K, 30 fps.

| File | What it does |
| --- | --- |
| RecorderRootView.swift | The screen: camera, script, controls, countdown, remote keys, take review hand-off |
| CameraController.swift | AVCaptureSession, picks a 1080p/4K format locked to 30 fps, rotation, start/pause/resume/stop |
| MovieWriter.swift | AVAssetWriter to .mp4, removes paused gaps so a take with pauses plays as one clip |
| CameraPreview.swift | Live preview layer and the thirds grid |
| PrompterEngine.swift | Frame-by-frame script scroll (CADisplayLink): fixed speed, or gliding to where your voice is |
| ScriptMatcher.swift | Finds your place in the script from the last few words heard (fuzzy, looks 30 words ahead, follows you back when you restart a line) |
| SpeechFollower.swift | Speech recognition on the camera's microphone audio, on the phone when supported, restarted every ~50 s |
| RemoteControl.swift | Apple Watch link, headphone play/pause, volume buttons |
| SectionTakes.swift | Record in parts: split at blank lines, takes per part, pick the best, join |
| ScriptWriterView.swift | AI script writer screen and the My voice screen (uses the shared AIClient and the key in AI settings) |
| ScriptCraft.swift | Script writer logic: voice profile, reading a link, lengths, calls to action, prompts, parsing hook/body/CTA and platform versions |
| ../Watch/ | The Apple Watch remote app (CueframeWatch target, embedded in the iPhone app) |
| TeleprompterView.swift | The script overlay: tap to pause, drag to scroll, pinch to resize, mirror; countdown overlay |
| ScriptStore.swift / ScriptLibraryView.swift | Saved scripts (Documents/Scripts.json), write, paste, import .txt/.rtf |
| TakeReviewView.swift | Play back a take; save to Photos, share, edit, retake |
| RecorderSettings.swift / RecorderSettingsView.swift | Saved preferences |
| Practice.swift | Practice mode: timing, pace, filler words, pauses, script coverage, report and per-script history |
| SeriesRecording.swift | Record a series: pick scripts and order, file each take to its own editor project, summary |
| BackgroundEffect.swift | Live background blur, color or photo (Vision person segmentation + Core Image), picker and preview |

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
  - Pace: recognition reports words in bursts about a beat late, so between reports the scroll keeps moving at your measured speaking rate (smoothed, 1.2 to 5.5 words a second), never more than 1.6 words past the last word heard, and stops within 0.6 s of you pausing.
  - Restarting a line: if the last four new words you say match, in order, a run of the script at least two words behind your place (within the last 60 words), the script goes back there. Revisions of words already heard never pull it back.
  - Ad-libbing: after six words that aren't in the script, a small "Off script, waiting for you" tag shows on the prompter. The script holds still and picks up as soon as you're back on it, including if you skip ahead (a jump past 30 words needs five words in a row to agree).
- Eye-contact layout (on by default): upright, the script is a short band about 3 lines tall and 74% wide right under the lens, read line at the top. Sideways, it is a column a third of the screen wide on the lens side, read line just above the middle, and the controls move to the other side.
- Record in parts: each paragraph is a part. A kept take moves you to the next part. The Takes list lets you star the best take of each part, re-record a part, and join the best takes in the editor.

Practice mode
- The Record / Practice switch above the record button. In Practice the button is blue: the script scrolls and you are timed and listened to, but nothing is recorded.
- After a run: real run time against the word-count estimate, words a minute (long pauses left out; 130 to 175 counts as natural), filler words (um, uh, like, basically, actually, literally, honestly, you know, I mean, kind of, sort of, and a few more), pauses over 2 seconds, and how much of the script you got through. Fillers the script itself uses aren't counted.
- Each script keeps its last 10 runs, and the report compares with the previous one.
- Uses the same speech recognizer as Follow my voice (shared when that is on, its own otherwise). Apple's recognizer often drops "um" and "uh", so those counts are a floor. Without the microphone or speech permission, only the run time is measured.

Record a series
- Scripts, +, Record a series: tick scripts, reorder, choose Back to back or not, Start.
- Each kept take becomes its own project in the Edit tab, named after its script, with the script attached for captions.
- Not back to back: the normal take review after each script (retake as often as you like; Keep files it and loads the next script).
- Back to back: no review. Each take is filed as soon as you stop, then an "Up next" card and a countdown (at least 3 s) roll into the next script.
- The bar under the top buttons shows "Series 2 of 5" with Skip and End. When it ends, a list of the projects made opens, each one tap from the editor.
- Record in parts is switched off during a series.

Background effect (no green screen)
- The person button in the top bar: Off, Blur (with strength), Color (includes chroma green and blue for keying later) or Photo (from your library).
- Vision person segmentation (balanced quality) runs on every frame on the camera queue; Core Image blends you over the new background on the GPU. The blur runs at quarter size. The effect is burned into the take, and the preview shows the processed frames, so what you see is what records.
- Can't be changed while recording; a change made then applies after the take.
- Speed: the segmentation model works at a small fixed size, so 4K costs mostly in the final blend and the encoder. If a frame takes over about 26 ms the mask is refreshed every other frame; over 33 ms the screen suggests switching to 1080p. 1080p should be fine on recent iPhones; 4K at 30 fps live is unproven until it runs on a real phone.

Remotes
- Apple Watch: record/stop, pause take, scroll/pause script, rewind, speed. Needs the Record tab open on the iPhone.
- AirPods or headphones: play/pause starts or pauses the script.
- Volume up (and Bluetooth selfie remotes, which send volume up): start or stop recording. Volume down: start or pause the script.
- Bluetooth page turners and keyboards: space, arrows and Return as before.

Script writer: Scripts, +, Write with AI (or Tighten with AI in the script editor, or long-press a script, Make platform versions).
- In: a topic, rough notes, a link (the page is fetched on the phone and its main text sent to the AI as source; logins, paywalls and video pages can't be read), or a finished script.
- Choices: 15 s, 30 s, 1 min, 90 s or 3 min (at 150 words a minute); tone; call to action (best fit, follow, comment, save, share, link in bio, or your own words).
- Write in my voice: My voice holds a few lines about you and up to 3 saved scripts that sound like you. Both go into the prompt as style guidance. Kept on the phone only.
- Out: title, hook, body and call to action shown separately. "Show 3 other hooks" gives alternatives; tap one to swap it in. Use this script saves it with the hook, body and call to action as separate paragraphs (so they become parts when recording in parts).
- Platform versions: one tap turns the draft (or the script in the box) into a TikTok (20 to 35 s, follow/comment), Instagram Reel (30 to 60 s, save/share) and Facebook (45 to 90 s, comment/share) version. Save each, or all, to Scripts as "Title · TikTok" and so on.
- Uses the Anthropic or OpenAI key from AI settings. Each script costs the AI provider's usual per-use price (a few cents at most).

Hand-off: "Edit" calls `EditorLauncher.open(urls:canvas:quality:)` after the review closes.

Not yet tested on a device, including the pace and restart behaviour of voice following, the script writer's link reading, practice mode, series recording, the background effect, voice following, the Watch app, headphone and volume-button remotes. Needs to be built in Xcode (or CI) and tried on an iPhone.
