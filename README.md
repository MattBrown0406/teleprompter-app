# Cueframe (working name)

An iPhone teleprompter camera and video editor for TikTok, Instagram and Facebook.

- **Record:** 9:16 or 16:9, 1080p or 4K at 30 fps, with the script scrolling under the lens. See [docs/recorder.md](docs/recorder.md).
- **Edit:** trim, text, music and captions. See [docs/editor.md](docs/editor.md).

## Build

Needs Xcode 16 and [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
xcodegen generate
open Cueframe.xcodeproj
```

Every push is compiled by GitHub Actions (`.github/workflows/build.yml`).
