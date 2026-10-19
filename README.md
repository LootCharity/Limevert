# Limevert

A free, open-source menu bar file converter for macOS. Drag files, tap ⌥ Option, and drop them on a ring of formats and tools. Results are saved next to the originals.

**[⬇ Download the latest release](https://github.com/LootCharity/Limevert/releases/latest)**

## Features

- **Images:** JPEG, HEIC, AVIF, TIFF, GIF, BMP, ICNS, PDF; compress, strip metadata, resize, rotate, flip, remove background, read QR codes, combine into a PDF
  - Editors: **crop** (with aspect ratios), **adjust** (exposure, contrast, highlights, shadows, saturation, warmth, sharpness), **annotate** (pen, highlighter, arrows, shapes, text), **redact** (pixelate, blur or black out, with automatic face and text detection), **frame** (gradient backgrounds, padding, rounded corners, shadow) and **collage**
- **Video:** MP4, M4V, MOV, GIF; compress, strip metadata, extract audio, mute, join clips
  - Editors: **trim**, **split** into parts, change **speed** (0.25×–4×, pitch kept) and save **snapshots** of frames
- **Audio:** M4A, ALAC, WAV, AIFF, FLAC, CAF; normalize volume, mono, stereo
  - Editors: **trim** (with automatic silence trimming), **bleep** or mute sections, and render a **visualizer** video
- **PDF:** pages to PNG/JPEG, text, RTF; compress, merge, split into pages, strip metadata
  - Editor: **organize** pages (reorder, rotate, delete)
- **Documents:** DOCX, RTF, TXT, HTML, ODT, Markdown, PDF
- **Subtitles:** SRT ↔ VTT
- **Any file:** Zip/Unzip, Copy Paths, AirDrop, Move To…, open in Terminal
- **Float:** an always-on-top shelf for carrying files between apps

Everything runs locally with macOS's built-in frameworks. No account, no network access, no paid tier.

## Install

1. Download `Limevert-<version>.dmg` from [Releases](https://github.com/LootCharity/Limevert/releases/latest), open it and drag **Limevert** into **Applications**.
2. Open Limevert. Because this build isn't notarized by Apple, macOS says it can't verify the developer.
3. Go to **System Settings → Privacy & Security**, scroll down and click **Open Anyway**, then confirm.

Or, in Terminal: `xattr -dr com.apple.quarantine /Applications/Limevert.app`

**Requirements:** macOS 14 or later, Apple silicon or Intel. The Liquid Glass wheel appears on macOS 26 and later; earlier versions get the classic wheel.

## Use

- Start dragging files from Finder or any app, then tap **⌥ Option** (changeable in Settings). Drop on a petal.
- Or drop files on the menu bar icon, or choose **Convert Files…** from its menu.

## Build from source

Needs only the Command Line Tools (no Xcode).

```sh
./build.sh                # builds ~/Library/Caches/Limevert-build/Limevert.app
./build.sh --install      # also copies it to /Applications
./release.sh              # universal build packaged as a DMG
```

## License

[MIT](LICENSE). Limevert is an independent project and isn't affiliated with any other app or company.
