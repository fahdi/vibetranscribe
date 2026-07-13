# VibeTranscribe Mac App — Design Spec

Date: 2026-07-13 · Status: Approved (user) · Timebox: ~1 hour build

## Goal

A simple native macOS app: drag-and-drop audio files or pick a folder, batch-transcribe
everything locally for free. Urdu support is a hard requirement (primary language),
plus English and other languages, with optional translation to English.

## Architecture

- `mac/` directory in this repo. SwiftUI app built as a Swift Package executable —
  no `.xcodeproj`. A `scripts/make-app.sh` script wraps the release binary into a
  double-clickable `VibeTranscribe.app`.
- Engine: `whisper-cli` from Homebrew's `whisper-cpp` (Metal-accelerated). The app
  shells out via `Process`. No Python, no server.
- Audio normalization: every input converted to 16 kHz mono WAV via `ffmpeg` before
  whisper sees it, so mp3/m4a/wav/flac/aiff/ogg/voice-memos all work.
- Model: `ggml-small.bin` (~466 MB) stored at
  `~/Library/Application Support/VibeTranscribe/models/`. Decent Urdu, matches the
  CLI default. In-app downloader with progress if missing.

## Components

| Unit | Responsibility |
|------|----------------|
| `VibeTranscribeApp` | @main entry, window scene |
| `TranscriptionJob` | model: id, source URL, status (queued/converting/transcribing/done/failed), transcript, error |
| `JobQueue` (@MainActor ObservableObject) | ordered job list, sequential processor loop, ingest of files/folders (recursive, audio extensions only) |
| `WhisperEngine` | locate whisper-cli + model, ffmpeg convert to temp wav, run transcription, return text; per-file cleanup of temp wav |
| `ModelDownloader` | URLSession download with progress to models dir |
| `SetupView` | shown when binary or model missing; explains brew install, offers model download button |
| `ContentView` | drop zone (files + folders), Choose Folder… button, Translate-to-English toggle (default ON), job list |
| `JobRowView` | filename, status badge/spinner, click to expand transcript, Copy button |

## Behavior

- Output: `<audioname>.txt` written next to each source file. Transcript also kept
  in-memory for in-app viewing/copying.
- Translate toggle ON → `whisper-cli --translate -l auto`; OFF → `-l auto` (original language).
- Sequential processing (Metal saturates on one job; simpler state).
- Per-file failure marks that row failed with the error message; queue continues.
- Duplicate drops of the same file while queued/processing are ignored.
- Binary discovery order: `/opt/homebrew/bin/whisper-cli`, `/usr/local/bin/whisper-cli`, `PATH`.

## Error handling

- Missing whisper-cli or model → SetupView gate, not a crash.
- ffmpeg failure (corrupt/unsupported file) → job failed with stderr excerpt.
- whisper non-zero exit → job failed with stderr excerpt.
- Output .txt write failure (e.g. read-only volume) → job done-with-warning; transcript still viewable in app.

## Testing

- Engine E2E: synthesize speech with macOS `say`, convert, transcribe, assert text contains expected words.
- Manual: drag mixed folder (wav + m4a + junk file), verify junk skipped, txt outputs appear.

## Out of scope (this hour)

AI summaries, live recording, code signing/notarization, model management UI beyond
one download, parallel transcription, App Store.
