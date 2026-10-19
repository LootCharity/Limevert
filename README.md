# Limevert

A menu bar file converter for macOS 14+. Drag files, tap ⌥ Option, and drop them on a ring of formats and tools. Results are saved next to the originals.

- **Images:** JPEG, HEIC, TIFF, GIF, BMP, ICNS, PDF; compress, strip metadata, resize, rotate, read QR codes
- **Video:** MP4, M4V, MOV, GIF; compress, strip metadata, extract audio
- **Audio:** M4A, ALAC, WAV, AIFF, FLAC, CAF
- **PDF:** pages to PNG/JPEG, text, RTF; compress, merge, strip metadata
- **Documents:** DOCX, RTF, TXT, HTML, ODT, Markdown, PDF
- **Subtitles:** SRT ↔ VTT
- **Any file:** Zip/Unzip, Copy Paths, AirDrop, Move To…, open in Terminal
- **Float:** an always-on-top shelf for carrying files between apps

## Build

Needs only the Command Line Tools (no Xcode).

```sh
./build.sh            # builds ~/Library/Caches/Limevert-build/Limevert.app
./build.sh --install  # also copies it to /Applications and relaunches
```
