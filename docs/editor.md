# Editor (Edit tab)

Native Swift, SwiftUI and AVFoundation, iOS 17+. Lives in `Editor/`, shares `App/` and `Shared/` with the recorder.

## What it does (v1)
- **Projects**: Edit tab lists saved projects (auto-saved as JSON in Documents/Projects). Start a new edit from Photos (multi-select, keeps order) or straight from a finished recording (`EditorLauncher.open`).
- **Clips**: trim (handles over a filmstrip), split at playhead, merge by adding more clips (+ at the end of the timeline), reorder (long-press a clip), duplicate, delete, reverse (clips up to 60 s), speed 0.1x to 8x with natural voice pitch, clip volume and mute.
- **Canvas**: 9:16, 1:1, 4:5, 16:9. Fill or Fit per clip, pinch/drag to zoom and reposition, rotate, mirror. Background behind fitted clips: blurred video or a solid color.
- **Look**: 11 original filters with strength, plus brightness, contrast, saturation, warmth, vignette, sharpen. "Apply to all clips" on each.
- **Transitions**: cut, dissolve, dip to black/white, slide, push up, wipe, zoom, blur; 0.2 to 1.5 s; apply to all cuts. Clip sound crossfades with the picture.
- **Text**: any number of text layers; 6 font styles, color, size, plain/box/pill background, outline, shadow, alignment; animations fade, pop, rise, typewriter. Drag, pinch, twist in the preview; drag/resize its bar on the timeline.
- **Auto captions**: on-device speech recognition of the clips' sound, grouped into short timed captions (words per caption, caps, position). Each caption is a normal editable text layer; "use this style for all captions".
- **Audio**: music from Files or the sound of any video in Photos; voiceover recorded at the playhead while the video plays muted. Per-sound volume, fade in/out, loop, split, move, trim. "Lower all clip sound to 30%" for music beds.
- **Auto-cut mistakes** (Auto-cut tool): finds dead air at the start and end, pauses over a chosen length, "um"/"uh" and lines you started again. Review each cut (tap to hear it, untick to keep), then cut them all in one tap. One undo step brings them back.
- **Post everywhere** (Export): tick 9:16, 1:1, 4:5 and 16:9 to export one file per shape from the same edit. "Keep my face centred" finds your face (Vision, on device) and makes the crop follow it. Also in the Canvas panel.
- **Animated captions**: word-by-word looks (Highlight, Word box, One word, Reveal, Plain). With a script (passed by the recorder or picked from saved scripts), captions use the script's exact words, timed to the speech. Style all captions at once: font (including the brand font), colours, spoken-word colour, size, background, outline.
- **Subtitles**: add lines at the playhead, edit any line's words, share an .srt file.
- **Brand kit** (Edit tab, seal icon, or the Brand tool): logo with corner, size and opacity; three colours; font style or an imported .ttf/.otf; intro and outro clips; optional "add to every new video".
- **Clean audio**: high-pass for rumble, spectral noise reduction from the quiet parts of the take, voice leveling to about -18 dBFS and a peak limiter. Light, Standard or Strong. Makes a separate sound file; the original stays and undo switches back.
- **AI help** (AI tool): post caption and hashtags for TikTok, Instagram or Facebook (works offline with on-device keyword hashtags when no key is set); fix caption words; add a hook title. Uses the Anthropic or OpenAI key from AI settings (Shared/AISettingsView, stored in the Keychain).
- **B-roll and cutaways** (B-roll tool): lay your own photos, screen recordings or clips over the talking head at the playhead while your voice keeps playing. Layouts: full screen, in a box, or B-roll full screen with you in a bubble (good for screen recordings). Photos get a slow push-in; everything fades in and out. Drag the purple bar on the timeline to move or trim it. "Suggest cutaways" sends what you say (with times) to the AI and lists where a cutaway would help and what to show; tap Add media on any idea.
- **Eye-contact check** (B-roll tool): Vision face landmarks on the device find moments you clearly look away from the lens (eyes to the side, looking down, head turned) and list them so you can cover each with B-roll. It does not change your eyes: Apple has no API for gaze redirection on recorded video, and an eye warp looks uncanny. Small reading movements next to the lens aren't flagged.
- **Hook test** (Hooks tool): mark where your opening line ends (or find it from the script), then add up to three other hooks. Write them yourself or with AI, record each one in the editor (the line sits under the lens), or pick a video. Each take gets captions in the video's caption style. Export then makes one video per hook with the same body (captions, music and B-roll move to fit).
- **Templates** (Templates tool): save an edit's look (filter, adjustments, framing, transition), caption style, music, brand (logo, intro, outro) and optionally on-screen text. Apply to any project in one tap, or star one to put it on every new video automatically (captions are made in the template's style when the editor opens).
- **Edit by text** (Edit by text tool): the take as words, heard once on the iPhone and kept with the project. Tap a word or a pause to strike it, or switch on "Select a stretch" and tap the first and last word of a part. "Auto-clean" marks every long pause, dead air, "um" and restarted line for you to check. Cut closes up the video and moves captions to match. Press and hold a word to hear it. Undo brings cuts back.
- **One-tap polish** (Polish tool): cleans the voice (noise, rumble, level, limiter) and gives every clip the same bright, clean look by measuring a few frames of each recording and setting its brightness, contrast, colour and white balance toward one shared target. Subtle, Natural or Bold. Your filter stays; the fix lives in Adjust so it can be fine-tuned. Remove polish puts everything back.
- **Long video to clips** (Clips tool): finds the strongest 15–30, 30–60 or 60–90 second moments in a long take. With an AI key the transcript (text only, with times) goes to the AI to pick hooks and complete points and write titles; without one the iPhone scores sentences for hooks, pace, fillers and clean endings. Each moment you keep becomes its own 9:16 project with your face kept in frame, captions in the long video's style, the hook title on screen for 3 s, pauses and "um"s closed up, and (optionally) a planned post on the calendar, one a day from tomorrow.
- **Undo/redo** for every edit (slider drags count as one step).
- **Export**: 1080p or 4K, 30 fps, H.264 or HEVC, .mp4. Exact canvas size (1080x1920, 2160x3840, etc). Save to Photos or share sheet (TikTok, Instagram, Facebook).

## How it works
- `Engine/CompositionBuilder` lays clips alternately on two video and two audio tracks so transitions overlap, applies speed with `scaleTimeRange`, and builds the audio mix.
- `Engine/CanvasCompositor` is a custom `AVVideoCompositing` that draws every frame with Core Image on the GPU: orientation, framing, filters, transitions, text. Preview and export use the same code, so the preview matches the file.
- Style-only edits (filters, text, framing) update a shared render plan without rebuilding the player, so dragging text or zooming is live.

## Build
```
brew install xcodegen
cd app && xcodegen && open Cueframe.xcodeproj
```
Pick your team under Signing, then run on your iPhone. Speech captions need a real device.

## Guesses to confirm
- Name "Cueframe", accent coral on dark graphite: placeholders.
- Default export: H.264 for 1080p (plays everywhere), HEVC for 4K (half the size).
- HDR (Dolby Vision) iPhone footage is converted to standard range in edits.
- No built-in music library (licensing); Apple Music songs can't be used because they're copy protected.

## Not in v1 (good next steps)
Stickers/emoji, keyframe animation, automatic music ducking under voiceover, beat sync, chroma key, drafts in iCloud.
