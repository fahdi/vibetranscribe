# StenoDrop (Mac App)

Native macOS app for batch audio transcription. Drag in files or folders and every
audio file gets transcribed locally — offline, free, no API keys. Transcripts are
saved as `.txt` next to each source file and are also viewable/copyable in the app.

- **Engine:** `whisper-cli` (Homebrew `whisper-cpp`, Metal-accelerated) with the
  Whisper **small** model (~466 MB). Good Urdu support, plus ~100 other languages
  with auto-detection.
- **Translate to English** toggle (default on). Turn it off to keep the transcript
  in the spoken language.
- **Language picker** (default Auto-detect). Force the spoken language when
  auto-detection misfires on short clips — e.g. Urdu heard as Hindi. Both this
  and the translate toggle persist across launches.
- **Inputs:** wav, mp3, m4a, aac, flac, ogg/oga, opus, aiff, caf, amr, wma — plus
  video containers (mp4, mov, m4v, webm, mkv), from which the audio track is used.
  Everything is normalized to 16 kHz mono WAV via ffmpeg before transcription.
- Folders are scanned recursively; non-audio files are skipped. Jobs run
  sequentially; a failed file is marked with its error and the queue continues.

Requires macOS 14+.

## Record live

Click **Record** in the toolbar to capture from the microphone with a live
transcript that updates roughly every 15 seconds (using the current language
and translate settings). Stopping saves the full recording plus its transcript
to `~/Documents/StenoDrop/` as `Recording <date> at <time>.wav` and `.txt`.
First use prompts for microphone access — everything stays on your Mac.

## Prerequisites

```bash
brew install whisper-cpp ffmpeg
```

The Whisper model is not bundled. On first launch the app shows a setup screen
that checks for both tools and offers a one-click model download (to
`~/Library/Application Support/StenoDrop/models/ggml-small.bin`).

## Development

Plain Swift Package — no `.xcodeproj`.

```bash
cd mac
swift build
swift run
```

## Build the app bundle

```bash
cd mac
./scripts/make-app.sh
```

This builds a release binary, wraps it as `dist/StenoDrop.app`, and ad-hoc
signs it for local use (no notarization). Install it with:

```bash
cp -R dist/StenoDrop.app /Applications/
```

## Notes

- Output `.txt` goes next to the source file. If that location isn't writable
  (e.g. a read-only volume), the job is marked "Done (not saved)" and the
  transcript is still available in the app for copying.
- `whisper-cli` is located via `/opt/homebrew/bin`, `/usr/local/bin`, then `PATH`.
- Design spec: [`docs/superpowers/specs/2026-07-13-mac-app-design.md`](../docs/superpowers/specs/2026-07-13-mac-app-design.md)
